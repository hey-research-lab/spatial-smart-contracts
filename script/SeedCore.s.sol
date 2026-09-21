// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {CreditHub} from "../src/CreditHub.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
import {LoanTypes} from "../src/libraries/LoanTypes.sol";
import {QuoteHash} from "../src/libraries/QuoteHash.sol";
import {MockERC20, MockStockToken, MockAggregatorV3} from "../src/mocks/Mocks.sol";

/// @title SeedCore
/// @notice Exercises the main flows of a DeployCore deployment, with the deployer taking every side. It opens four
///         loans (three funded by one lender each and one split across two slices), adds collateral, makes one
///         partial and one full repayment, drops the price far enough to make a loan liquidatable, lets a
///         liquidator take the whole auction in one purchase, and cancels a nonce.
/// @dev Contract addresses come from `deployments/<chainId>.json`. Example:
///        forge script script/SeedCore.s.sol --rpc-url robinhood_testnet --broadcast
///      SeedDeep, SeedMore and SeedResume inherit from this contract and reuse its state and helpers.
contract SeedCore is Script {
    /// @dev Starting NVDAx price, 176.40 USD in 8 decimal feed units.
    int256 internal constant PRICE_OPEN = 176_40_000_000;
    /// @dev 135.00 USD, a fall of 23.5 percent from the start, which the 25 percent move cap still accepts.
    int256 internal constant PRICE_CRASH = 135_00_000_000;
    /// @dev 160.00 USD, a rise of 18.5 percent from the low, again within the move cap.
    int256 internal constant PRICE_RECOVER = 160_00_000_000;

    CreditHub internal hub;
    LiquidationAuction internal auction;
    MockERC20 internal usdg;
    MockStockToken internal stock;
    MockAggregatorV3 internal priceFeed;

    function run() external virtual {
        uint256 key = vm.envUint("PRIVATE_KEY");
        address self = vm.addr(key);
        _readCoreAddresses();

        vm.startBroadcast(key);

        // Push a new price round, mint test balances and approve the hub and the auction to pull funds.
        priceFeed.set(PRICE_OPEN);
        usdg.mint(self, 500_000e6);
        stock.mint(self, 2_000e18);
        usdg.approve(address(hub), type(uint256).max);
        stock.approve(address(hub), type(uint256).max);
        usdg.approve(address(auction), type(uint256).max);

        // Loan 1: 8,000 USDG over 30 days from a single lender at 8.50%, secured by 100 NVDAx (17,640 USDG).
        uint256 loan1 = _fill(self, key, 100e18, 8_000e6, 30 days, 1, _oneOffer(self, 8_000e6, 850, 30 days, 1));
        console2.log("Loan 1 opened", loan1);

        // Loan 2: 20,000 USDG over 14 days on 250 NVDAx, split into a 12,000 slice at 8.50% and 8,000 at 9.00%.
        LoanTypes.LendOffer[] memory offers = new LoanTypes.LendOffer[](2);
        offers[0] = _lendOffer(self, 12_000e6, 850, 14 days, 2);
        offers[1] = _lendOffer(self, 8_000e6, 900, 14 days, 3);
        uint256 loan2 = _fill(self, key, 250e18, 20_000e6, 14 days, 2, offers);
        console2.log("Loan 2 opened", loan2);

        // The borrower adds collateral to loan 1, pays 2,000 USDG off it and clears loan 2 entirely.
        hub.addCollateral(loan1, 10e18);
        hub.repay(loan1, 2_000e6);
        hub.repay(loan2, type(uint128).max);

        // Loan 3: 24,000 USDG over 7 days on 250 NVDAx (44,100 USDG), so 54.4% LTV, just under the 55% limit.
        uint256 loan3 = _fill(self, key, 250e18, 24_000e6, 7 days, 3, _oneOffer(self, 24_000e6, 900, 7 days, 4));
        console2.log("Loan 3 opened", loan3);

        // A price of 135.00 lifts loan 3 to 71.1% LTV, above the 70% trigger, while loan 1 remains comfortable.
        priceFeed.set(PRICE_CRASH);
        auction.startAuction(loan3);
        console2.log("Auction opened on loan", loan3);
        // Ask for all of the collateral; the auction cuts the fill down so proceeds match the target exactly.
        auction.buy(loan3, 250e18, "");
        console2.log("Auction cleared on loan", loan3);

        // Restore the price in two moves that each respect the cap, opening loan 4 at the halfway price.
        priceFeed.set(PRICE_RECOVER);
        uint256 loan4 = _fill(self, key, 50e18, 3_000e6, 14 days, 4, _oneOffer(self, 3_000e6, 875, 14 days, 5));
        console2.log("Loan 4 opened", loan4);
        priceFeed.set(PRICE_OPEN);

        // Nonce 6 was never signed into an offer; cancelling it records a cancellation on chain.
        hub.cancel(6);

        vm.stopBroadcast();

        (uint256 principalLeft, uint256 interestLeft) = hub.debtOf(loan1);
        console2.log("Loan 1 principal owed", principalLeft);
        console2.log("Loan 1 interest owed", interestLeft);
        console2.log("Loan 2 status (4 = Repaid)", uint8(hub.getLoan(loan2).status));
        console2.log("Loan 3 status (5 = Settled)", uint8(hub.getLoan(loan3).status));
        console2.log("Loan 4 health factor (wad)", hub.healthFactor(loan4));
    }

    // ---------------------------------------------------------------------------------------------------------
    // Shared helpers
    // ---------------------------------------------------------------------------------------------------------

    /// @dev Loads the hub, the auction and the three mocks from this chain's deployment file.
    function _readCoreAddresses() internal {
        string memory json = vm.readFile(string.concat("deployments/", vm.toString(block.chainid), ".json"));
        hub = CreditHub(vm.parseJsonAddress(json, ".CreditHub"));
        auction = LiquidationAuction(vm.parseJsonAddress(json, ".LiquidationAuction"));
        usdg = MockERC20(vm.parseJsonAddress(json, ".USDG"));
        stock = MockStockToken(vm.parseJsonAddress(json, ".StockToken"));
        priceFeed = MockAggregatorV3(vm.parseJsonAddress(json, ".StockFeed"));
    }

    /// @dev Signs every offer with `key` and submits them against a fresh borrow request capped at 9.00% APR.
    function _fill(
        address borrower,
        uint256 key,
        uint256 collateral,
        uint256 principal,
        uint32 term,
        uint256 salt,
        LoanTypes.LendOffer[] memory offers
    ) internal returns (uint256) {
        bytes[] memory signatures = new bytes[](offers.length);
        for (uint256 idx; idx < offers.length; ++idx) {
            signatures[idx] = _signOffer(key, offers[idx]);
        }
        return hub.originate(_borrowRequest(borrower, collateral, principal, 900, term, salt), "", offers, signatures);
    }

    /// @dev Wraps a single lend offer in a one-element array.
    function _oneOffer(address maker, uint256 principalMax, uint16 aprBps, uint32 term, uint256 nonce)
        internal
        view
        returns (LoanTypes.LendOffer[] memory list)
    {
        list = new LoanTypes.LendOffer[](1);
        list[0] = _lendOffer(maker, principalMax, aprBps, term, nonce);
    }

    /// @dev An NVDAx/USDG lend offer with a 1,000 USDG minimum fill, a 55% LTV ceiling, a week until expiry, no
    ///      flags and a salt derived from the maker and nonce.
    function _lendOffer(address maker, uint256 principalMax, uint16 aprBps, uint32 term, uint256 nonce)
        internal
        view
        returns (LoanTypes.LendOffer memory)
    {
        return LoanTypes.LendOffer({
            maker: maker,
            side: LoanTypes.Side.Lend,
            collateralToken: address(stock),
            loanToken: address(usdg),
            principalMin: 1_000e6,
            principalMax: principalMax,
            aprBps: aprBps,
            maxLtvBps: 5500,
            termSeconds: term,
            expiry: uint40(block.timestamp + 7 days),
            nonce: nonce,
            salt: keccak256(abi.encode(maker, nonce)),
            requestId: bytes32(0),
            flags: 0
        });
    }

    /// @dev An NVDAx/USDG borrow request that must be filled within a day.
    function _borrowRequest(
        address borrower,
        uint256 collateral,
        uint256 principal,
        uint16 maxApr,
        uint32 term,
        uint256 salt
    ) internal view returns (LoanTypes.BorrowRequest memory) {
        return LoanTypes.BorrowRequest({
            borrower: borrower,
            collateralToken: address(stock),
            loanToken: address(usdg),
            collateralAmount: collateral,
            principal: principal,
            maxAprBps: maxApr,
            termSeconds: term,
            fillDeadline: uint40(block.timestamp + 1 days),
            salt: bytes32(salt)
        });
    }

    /// @dev Produces the EIP-712 signature the hub expects on a lend offer, packed as r, s, v.
    function _signOffer(uint256 key, LoanTypes.LendOffer memory offer) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                QuoteHash.LEND_OFFER_TYPEHASH,
                offer.maker,
                uint8(offer.side),
                offer.collateralToken,
                offer.loanToken,
                offer.principalMin,
                offer.principalMax,
                offer.aprBps,
                offer.maxLtvBps,
                offer.termSeconds,
                offer.expiry,
                offer.nonce,
                offer.salt,
                offer.requestId,
                offer.flags
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", hub.domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }
}
