// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ReserveAdapter} from "../src/ReserveAdapter.sol";
import {LoanTypes} from "../src/libraries/LoanTypes.sol";

/// @title ReserveTest
/// @notice Covers the reserve adapter: tracking each lender's shares of a single ERC-4626 vault, emptying a
///         position completely with its yield and any rounding remainder, stopping one lender drawing on another's
///         balance, and allowing only the hub to move reserve funds on a lender's behalf.
contract ReserveTest is BaseTest {
    function setUp() public override {
        super.setUp();
        vm.prank(lender1);
        usdg.approve(address(idle), type(uint256).max);
    }

    function test_withdrawAllClearsPositionIncludingYield() public {
        vm.prank(lender1);
        idle.deposit(10_000e6);
        // Sending USDG straight to the vault stands in for yield, lifting the price of each share.
        usdg.mint(address(vault), 333e6);
        uint256 reported = idle.balanceOf(lender1);
        assertGt(reported, 10_000e6);

        // Withdrawing the reported amount converts it to shares with rounding down, which may leave a share
        // behind. Find out how much on a snapshot and then restore the earlier state.
        uint256 snapshot = vm.snapshotState();
        vm.prank(lender1);
        idle.withdraw(reported, lender1);
        uint256 dust = idle.shares(lender1);
        vm.revertToState(snapshot);

        uint256 walletBefore = usdg.balanceOf(lender1);
        vm.prank(lender1);
        uint256 got = idle.withdrawAll(lender1);
        assertEq(idle.shares(lender1), 0, "lender should have no shares left");
        assertGe(got, reported);
        assertGe(got, 10_000e6 + dust, "payout should cover deposit, yield and the leftover share");
        assertEq(usdg.balanceOf(lender1) - walletBefore, got);
    }

    function test_withdrawAllRevertsOnEmptyPosition() public {
        vm.prank(lender1);
        vm.expectRevert(ReserveAdapter.InsufficientReserve.selector);
        idle.withdrawAll(lender1);
    }

    function test_hubAddressCannotBeZero() public {
        ReserveAdapter fresh = new ReserveAdapter(riskConfig, IERC4626(address(vault)));
        vm.prank(gov);
        vm.expectRevert(ReserveAdapter.ZeroHub.selector);
        fresh.setDesk(address(0));
    }

    function test_zeroAmountDepositAndWithdrawRevert() public {
        vm.prank(lender1);
        vm.expectRevert(ReserveAdapter.ZeroAmount.selector);
        idle.deposit(0);

        vm.prank(lender1);
        idle.deposit(1_000e6);
        vm.prank(lender1);
        vm.expectRevert(ReserveAdapter.ZeroAmount.selector);
        idle.withdraw(0, lender1);
    }

    function test_withdrawToZeroAddressReverts() public {
        vm.prank(lender1);
        idle.deposit(1_000e6);

        vm.prank(lender1);
        vm.expectRevert(ReserveAdapter.ZeroRecipient.selector);
        idle.withdraw(1e6, address(0));
        vm.prank(lender1);
        vm.expectRevert(ReserveAdapter.ZeroRecipient.selector);
        idle.withdrawAll(address(0));
        assertEq(idle.balanceOf(lender1), 1_000e6);
    }

    function test_lenderCannotWithdrawPastOwnShares() public {
        vm.prank(lender1);
        idle.deposit(10_000e6);
        vm.prank(lender2);
        usdg.approve(address(idle), type(uint256).max);
        vm.prank(lender2);
        idle.deposit(10_000e6);

        // The adapter has 20,000 in total, 10,000 from each lender, and lender1 is limited to its own half.
        vm.prank(lender1);
        vm.expectRevert(ReserveAdapter.InsufficientReserve.selector);
        idle.withdraw(10_001e6, lender1);
        assertEq(idle.shares(lender1), idle.shares(lender2));
    }

    function test_withdrawForIsRestrictedToHub() public {
        vm.prank(lender1);
        idle.deposit(10_000e6);
        vm.prank(lender2);
        vm.expectRevert(ReserveAdapter.NotHub.selector);
        idle.withdrawFor(lender1, 1e6, lender2);
    }

    /// Removing the vault from the whitelist blocks fresh deposits. Existing balances can still be pulled out,
    /// so lenders are never trapped in a vault that governance no longer approves.
    function test_delistedVaultBlocksDepositsOnly() public {
        vm.prank(lender1);
        idle.deposit(10_000e6);

        vm.prank(gov);
        riskConfig.setVaultWhitelisted(address(vault), false);

        vm.prank(lender1);
        vm.expectRevert(ReserveAdapter.VaultNotWhitelisted.selector);
        idle.deposit(1_000e6);

        uint256 before = usdg.balanceOf(lender1);
        vm.prank(lender1);
        idle.withdraw(4_000e6, lender1);
        assertEq(usdg.balanceOf(lender1) - before, 4_000e6);
        vm.prank(lender1);
        assertGe(idle.withdrawAll(lender1), 6_000e6);
    }

    /// Repayments to a lender who lent out of the reserve normally go back into the vault. If the vault has been
    /// delisted in the meantime, the money is sent to the lender's wallet so the repayment does not fail.
    function test_repaymentFallsBackToWalletAfterVaultDelisted() public {
        vm.prank(lender1);
        idle.deposit(30_000e6);

        LoanTypes.LendOffer[] memory offers = new LoanTypes.LendOffer[](1);
        bytes[] memory sigs = new bytes[](1);
        offers[0] = _offer(lender1, 20_000e6, 850, 1, LoanTypes.FLAG_PARK_IDLE);
        sigs[0] = _sign(lender1Pk, offers[0]);
        vm.prank(borrower);
        uint256 loanId = hub.originate(_request(250e18, 20_000e6, 900), "", offers, sigs);

        vm.prank(gov);
        riskConfig.setVaultWhitelisted(address(vault), false);

        vm.warp(block.timestamp + 30 days);
        (uint256 p, uint256 i) = hub.debtOf(loanId);
        uint256 walletBefore = usdg.balanceOf(lender1);
        uint256 sharesBefore = idle.shares(lender1);

        vm.expectEmit(true, false, false, false, address(idle));
        emit ReserveAdapter.ParkingSkipped(lender1, 0);
        vm.prank(borrower);
        hub.repay(loanId, p + i);

        assertEq(idle.shares(lender1), sharesBefore, "no shares should be added to a delisted vault");
        assertGt(usdg.balanceOf(lender1) - walletBefore, 20_000e6, "wallet should receive principal and interest");
        assertEq(uint8(hub.getLoan(loanId).status), uint8(LoanTypes.LoanStatus.Repaid));
    }
}
