// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {CreditHub} from "../src/CreditHub.sol";
import {ReserveAdapter} from "../src/ReserveAdapter.sol";
import {LoanTypes} from "../src/libraries/LoanTypes.sol";
import {QuoteHash} from "../src/libraries/QuoteHash.sol";
import {MockERC20, MockStockToken, MockAggregatorV3} from "../src/mocks/Mocks.sol";

/// @title Seed
/// @notice Gives a mock-backed Deploy.s.sol deployment some history to look at. It mints test balances, opens a
///         loan with one lender and another split into two slices, adds collateral, repays part of one loan and
///         all of the other, parks lender capital in the vault and cancels a nonce. A single wallet acts as
///         borrower, lender and signer, since Deploy.s.sol credentialed the deployer for all of those roles.
/// @dev Contract addresses come from `deployments/<chainId>.json`. Example:
///        forge script script/Seed.s.sol --rpc-url robinhood_testnet --broadcast
contract Seed is Script {
    /// @dev NVDAx price pushed to the mock feed, 176.40 USD in 8 decimals.
    uint256 internal constant STOCK_PRICE_E8 = 176_40_000_000;

    CreditHub internal hub;
    ReserveAdapter internal reserve;
    MockERC20 internal usdg;
    MockStockToken internal stock;
    MockAggregatorV3 internal priceFeed;

    function run() external {
        uint256 key = vm.envUint("PRIVATE_KEY");
        address self = vm.addr(key);

        string memory json = vm.readFile(string.concat("deployments/", vm.toString(block.chainid), ".json"));
        hub = CreditHub(vm.parseJsonAddress(json, ".CreditHub"));
        reserve = ReserveAdapter(vm.parseJsonAddress(json, ".ReserveAdapter"));
        usdg = MockERC20(vm.parseJsonAddress(json, ".USDG"));
        stock = MockStockToken(vm.parseJsonAddress(json, ".StockToken"));
        priceFeed = MockAggregatorV3(vm.parseJsonAddress(json, ".StockFeed"));

        vm.startBroadcast(key);

        // Refresh the feed so the guard sees a recent price, then mint balances and grant allowances.
        priceFeed.set(int256(STOCK_PRICE_E8));
        usdg.mint(self, 500_000e6);
        stock.mint(self, 1_000e18);
        usdg.approve(address(hub), type(uint256).max);
        stock.approve(address(hub), type(uint256).max);
        usdg.approve(address(reserve), type(uint256).max);

        // Loan 1: 8,000 USDG over 30 days from a single lender at 8.50%, secured by 100 NVDAx (17,640 USDG).
        LoanTypes.LendOffer[] memory offers = new LoanTypes.LendOffer[](1);
        bytes[] memory signatures = new bytes[](1);
        offers[0] = _lendOffer(self, 8_000e6, 850, 30 days, 1);
        signatures[0] = _signOffer(key, offers[0]);
        uint256 loan1 = hub.originate(_borrowRequest(self, 100e18, 8_000e6, 900, 30 days, 1), "", offers, signatures);
        console2.log("Loan 1 opened", loan1);

        // Loan 2: 20,000 USDG over 14 days on 250 NVDAx, split into a 12,000 slice at 8.50% and 8,000 at 9.00%.
        offers = new LoanTypes.LendOffer[](2);
        signatures = new bytes[](2);
        offers[0] = _lendOffer(self, 12_000e6, 850, 14 days, 2);
        offers[1] = _lendOffer(self, 8_000e6, 900, 14 days, 3);
        signatures[0] = _signOffer(key, offers[0]);
        signatures[1] = _signOffer(key, offers[1]);
        uint256 loan2 = hub.originate(_borrowRequest(self, 250e18, 20_000e6, 900, 14 days, 2), "", offers, signatures);
        console2.log("Loan 2 opened", loan2);

        // The borrower adds collateral to loan 1 and pays 2,000 USDG off it. Loan 2 is cleared by passing the
        // largest possible amount, which the hub reduces to what is actually owed.
        hub.addCollateral(loan1, 10e18);
        hub.repay(loan1, 2_000e6);
        hub.repay(loan2, type(uint128).max);

        // As a lender, move 25,000 USDG into the approved vault via the reserve adapter.
        reserve.deposit(25_000e6);

        // Nonce 4 is never used, so cancelling it simply leaves a cancellation on record.
        hub.cancel(4);

        vm.stopBroadcast();

        (uint256 principalLeft, uint256 interestLeft) = hub.debtOf(loan1);
        console2.log("Loan 1 principal owed", principalLeft);
        console2.log("Loan 1 interest owed", interestLeft);
        console2.log("Loan 2 status (4 = Repaid)", uint8(hub.getLoan(loan2).status));
        console2.log("Capital held in reserve", reserve.balanceOf(self));
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
