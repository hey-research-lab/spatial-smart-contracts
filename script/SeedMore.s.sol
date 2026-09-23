// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";
import {SeedCore} from "./SeedCore.s.sol";
import {RiskConfig} from "../src/RiskConfig.sol";
import {CredentialRegistry} from "../src/adapters/CredentialRegistry.sol";
import {SliceNote} from "../src/SliceNote.sol";
import {LoanTypes, Permissions} from "../src/libraries/LoanTypes.sol";

/// @title SeedMore
/// @notice Adds a further round of activity after SeedCore. It credentials and funds three extra wallets, opens
///         a loan split into three slices and two single-lender loans, takes repayments and a collateral top-up,
///         moves a slice note to a different eligible lender, has the guardian pause and unpause, lets the owner
///         enable the 90 day term, liquidates another loan across three auction purchases and cancels two more
///         nonces.
/// @dev Continues numbering from SeedCore, which spent nonces 1 to 6 and request salts 1 to 4, so nonces here
///      start at 7 and salts at 5. It relies on SeedCore's ids too: loan 4 gets repaid, and slice 1 (loan 1's
///      sole slice) is the one handed over.
contract SeedMore is SeedCore {
    function run() external override {
        uint256 key = vm.envUint("PRIVATE_KEY");
        address self = vm.addr(key);

        _readCoreAddresses();
        string memory json = vm.readFile(string.concat("deployments/", vm.toString(block.chainid), ".json"));
        RiskConfig riskConfig = RiskConfig(vm.parseJsonAddress(json, ".RiskConfig"));
        CredentialRegistry credentials = CredentialRegistry(vm.parseJsonAddress(json, ".CredentialRegistry"));
        SliceNote slices = SliceNote(vm.parseJsonAddress(json, ".SliceNote"));

        address lenderA = address(uint160(uint256(keccak256("spatial.seed.lenderA"))));
        address lenderB = address(uint160(uint256(keccak256("spatial.seed.lenderB"))));
        address borrowerC = address(uint160(uint256(keccak256("spatial.seed.borrowerC"))));

        vm.startBroadcast(key);

        priceFeed.set(PRICE_OPEN);
        usdg.mint(self, 250_000e6);
        stock.mint(self, 1_500e18);

        // Give the two lenders and the borrower at their fixed addresses credentials and some tokens.
        uint64 validUntil = uint64(block.timestamp + 180 days);
        credentials.attest(lenderA, Permissions.LENDER_PROFESSIONAL, "DE", 3, validUntil);
        credentials.attest(lenderB, Permissions.LENDER_RETAIL, "IE", 1, validUntil);
        credentials.attest(borrowerC, Permissions.BORROWER, "LT", 2, validUntil);
        usdg.transfer(lenderA, 25_000e6);
        usdg.transfer(lenderB, 5_000e6);
        stock.transfer(borrowerC, 40e18);

        // Loan 5: 35,000 USDG over 30 days on 400 NVDAx, from slices of 15,000 at 8.25%, 12,000 at 8.75% and
        // 8,000 at 9.00%.
        LoanTypes.LendOffer[] memory offers = new LoanTypes.LendOffer[](3);
        offers[0] = _lendOffer(self, 15_000e6, 825, 30 days, 7);
        offers[1] = _lendOffer(self, 12_000e6, 875, 30 days, 8);
        offers[2] = _lendOffer(self, 8_000e6, 900, 30 days, 9);
        uint256 loan5 = _fill(self, key, 400e18, 35_000e6, 30 days, 5, offers);
        console2.log("Loan 5 opened", loan5);

        // Loans 6 and 7: a single lender apiece, on 7 and 14 day terms respectively.
        uint256 loan6 = _fill(self, key, 60e18, 5_000e6, 7 days, 6, _oneOffer(self, 5_000e6, 800, 7 days, 10));
        uint256 loan7 = _fill(self, key, 120e18, 10_000e6, 14 days, 7, _oneOffer(self, 10_000e6, 850, 14 days, 11));
        console2.log("Loans 6 and 7 opened", loan6, loan7);

        // Part payments on loans 5 and 6, extra collateral on loan 7, and loan 4 from SeedCore paid off.
        hub.repay(loan5, 5_000e6);
        hub.repay(loan6, 1_500e6);
        hub.addCollateral(loan7, 20e18);
        hub.repay(4, type(uint128).max);

        // Hand slice 1 to lenderA. The slice note refuses recipients that lack a lender role.
        slices.transferFrom(self, lenderA, 1);
        console2.log("Slice 1 now held by", lenderA);

        // Acting as guardian, pause and resume originations; acting as owner, permit the 90 day term.
        riskConfig.setPaused(true, false);
        riskConfig.setPaused(false, false);
        riskConfig.setTermAllowed(90 days, true);

        // Loan 8: 28,800 USDG on 300 NVDAx, exactly at the LTV limit. Once the price falls to 135.00 it can be
        // liquidated, and three purchases clear the auction, the final one reduced to the remaining target.
        uint256 loan8 = _fill(self, key, 300e18, 28_800e6, 7 days, 8, _oneOffer(self, 28_800e6, 900, 7 days, 12));
        console2.log("Loan 8 opened", loan8);
        priceFeed.set(PRICE_CRASH);
        auction.startAuction(loan8);
        auction.buy(loan8, 60e18, "");
        auction.buy(loan8, 60e18, "");
        auction.buy(loan8, 300e18, "");
        console2.log("Auction cleared on loan", loan8);

        // Return to the opening price in two moves inside the cap, opening loan 9 in between.
        priceFeed.set(PRICE_RECOVER);
        uint256 loan9 = _fill(self, key, 80e18, 6_000e6, 90 days, 9, _oneOffer(self, 6_000e6, 875, 90 days, 13));
        console2.log("Loan 9 opened", loan9);
        priceFeed.set(PRICE_OPEN);

        hub.cancel(14);
        hub.cancel(15);

        vm.stopBroadcast();

        console2.log("Loan 4 status (4 = Repaid)", uint8(hub.getLoan(4).status));
        console2.log("Loan 8 status (5 = Settled)", uint8(hub.getLoan(loan8).status));
        console2.log("Slice 1 owner", slices.ownerOf(1));
        console2.log("90-day term allowed", riskConfig.termAllowed(90 days));
    }
}
