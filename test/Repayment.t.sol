// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {LoanTypes} from "../src/libraries/LoanTypes.sol";
import {ICreditHub} from "../src/interfaces/ICreditHub.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";

/// @title RepaymentTest
/// @notice Covers paying a loan back. It checks simple interest charged slice by slice with its minimum period,
///         settling in full or in part, adding collateral, a stranger paying for the borrower, and that the
///         borrower can still repay after maturity within the grace window, while the guardian has paused
///         activity, and once a rollover has failed.
contract RepaymentTest is BaseTest {
    function test_interestIsChargedSliceBySlice() public {
        uint256 loanId = _originateExample();
        vm.warp(block.timestamp + 30 days);
        (uint256 p, uint256 i) = hub.debtOf(loanId);
        assertEq(p, 20_000e6);
        // Thirty days on 5,000 at 850 bps, 10,000 at 890 bps and 5,000 at 900 bps is 34.93, 73.15 and 36.99,
        // a total of 145.07 USDG.
        assertApproxEqAbs(i, 145_07e4, 2e4);
    }

    function test_minimumInterestPeriodIsCharged() public {
        uint256 loanId = _originateExample();
        vm.warp(block.timestamp + 1 hours);
        (, uint256 i) = hub.debtOf(loanId);
        // Only an hour has gone by, yet each slice is charged the three-day minimum.
        uint256 minimumCharge =
            _interestFor(5_000e6, 850, 3 days) + _interestFor(10_000e6, 890, 3 days) + _interestFor(5_000e6, 900, 3 days);
        assertEq(i, minimumCharge);
    }

    function test_fullRepaymentReturnsCollateralAndPaysEachLender() public {
        uint256 loanId = _originateExample();
        uint256 l1Before = usdg.balanceOf(lender1);
        uint256 l2Before = usdg.balanceOf(lender2);
        uint256 l3Before = usdg.balanceOf(lender3);
        uint256 feeVaultBefore = usdg.balanceOf(address(feeVault));
        uint256 nvdaBefore = nvda.balanceOf(borrower);

        vm.warp(block.timestamp + 30 days);
        (uint256 p, uint256 i) = hub.debtOf(loanId);
        vm.prank(borrower);
        hub.repay(loanId, p + i);

        LoanTypes.Loan memory L = hub.getLoan(loanId);
        assertEq(uint8(L.status), uint8(LoanTypes.LoanStatus.Repaid));
        assertEq(L.collateralAmount, 0);
        assertEq(nvda.balanceOf(borrower) - nvdaBefore, 250e18);
        assertEq(hub.exposure(address(nvda)), 0);

        // Lenders get their principal and 9,000 bps of the interest on their slice. The remaining 1,000 bps is
        // the protocol's cut and is sent to the fee vault.
        uint256 i1 = _interestFor(5_000e6, 850, 30 days);
        uint256 i2 = _interestFor(10_000e6, 890, 30 days);
        assertEq(usdg.balanceOf(lender1) - l1Before, 5_000e6 + i1 - i1 * 1000 / 10_000);
        assertEq(usdg.balanceOf(lender2) - l2Before, 10_000e6 + i2 - i2 * 1000 / 10_000);
        assertGt(usdg.balanceOf(lender3) - l3Before, 5_000e6);
        assertApproxEqAbs(usdg.balanceOf(address(feeVault)) - feeVaultBefore, i * 1000 / 10_000, 3);

        // The slice notes are burned on settlement, which makes ownerOf revert.
        vm.expectRevert();
        sliceNote.ownerOf(L.sliceIds.length == 0 ? 1 : L.sliceIds[0]);
    }

    function test_partialRepaymentShrinksEverySliceEqually() public {
        uint256 loanId = _originateExample();
        vm.warp(block.timestamp + 15 days);
        (, uint256 interestBefore) = hub.debtOf(loanId);

        vm.prank(borrower);
        hub.repay(loanId, interestBefore + 4_000e6);

        (uint256 p, uint256 i) = hub.debtOf(loanId);
        assertEq(p, 16_000e6);
        assertEq(i, 0, "accrued interest should be cleared");
        LoanTypes.Loan memory L = hub.getLoan(loanId);
        assertEq(uint8(L.status), uint8(LoanTypes.LoanStatus.Active));
        assertEq(L.collateralAmount, 250e18, "collateral should stay in escrow");
        // Paying down 4,000 of 20,000 removes one fifth, and each slice loses a fifth too, leaving 4,000, 8,000
        // and 4,000.
        assertEq(hub.getSlice(L.sliceIds[0]).principal, 4_000e6);
        assertEq(hub.getSlice(L.sliceIds[1]).principal, 8_000e6);
        assertEq(hub.getSlice(L.sliceIds[2]).principal, 4_000e6);
        assertEq(hub.exposure(address(nvda)), 16_000e6);
    }

    function test_addingCollateralImprovesHealthFactor() public {
        uint256 loanId = _originateExample();
        uint256 hfBefore = hub.healthFactor(loanId);
        vm.prank(borrower);
        hub.addCollateral(loanId, 50e18);
        assertGt(hub.healthFactor(loanId), hfBefore);
        assertEq(hub.getLoan(loanId).collateralAmount, 300e18);
    }

    /// Both new loans and liquidations are paused and maturity passed 12 hours ago, yet the borrower can still pay.
    function test_repayWorksInGraceWindowWhilePaused() public {
        uint256 loanId = _originateExample();
        vm.prank(guardian);
        riskConfig.setPaused(true, true);
        vm.warp(block.timestamp + 30 days + 12 hours);
        (uint256 p, uint256 i) = hub.debtOf(loanId);
        vm.prank(borrower);
        hub.repay(loanId, p + i);
        assertEq(uint8(hub.getLoan(loanId).status), uint8(LoanTypes.LoanStatus.Repaid));
    }

    function test_thirdPartyCanRepayForBorrower() public {
        uint256 loanId = _originateExample();
        address friend = makeAddr("friend");
        usdg.mint(friend, 30_000e6);
        vm.warp(block.timestamp + 5 days);
        (uint256 p, uint256 i) = hub.debtOf(loanId);
        vm.startPrank(friend);
        usdg.approve(address(hub), type(uint256).max);
        hub.repay(loanId, p + i);
        vm.stopPrank();
        assertEq(uint8(hub.getLoan(loanId).status), uint8(LoanTypes.LoanStatus.Repaid));
        assertEq(nvda.balanceOf(borrower), 1_000e18, "released NVDA should go to the borrower rather than the payer");
    }

    function test_repayStillPossibleAfterRolloverFails() public {
        uint256 loanId = _originateExample();
        vm.prank(borrower);
        rollover.openRefinance(loanId);
        vm.warp(block.timestamp + 4 hours + 1);
        rollover.fail(loanId);
        assertEq(uint8(hub.getLoan(loanId).status), uint8(LoanTypes.LoanStatus.Defaulted));

        // After a failed rollover the loan is Defaulted and can be auctioned whatever its health. As long as no
        // keeper has started that auction, the borrower can still add collateral, clear the debt and recover
        // the escrow.
        vm.prank(borrower);
        hub.addCollateral(loanId, 10e18);
        assertEq(hub.getLoan(loanId).collateralAmount, 260e18);
        (uint256 p, uint256 i) = hub.debtOf(loanId);
        vm.prank(borrower);
        hub.repay(loanId, p + i);

        LoanTypes.Loan memory L = hub.getLoan(loanId);
        assertEq(uint8(L.status), uint8(LoanTypes.LoanStatus.Repaid));
        assertEq(L.collateralAmount, 0);
        assertEq(nvda.balanceOf(borrower), 1_000e18, "borrower should hold all of its NVDA again");
        assertEq(hub.exposure(address(nvda)), 0);

        // With the loan settled there is nothing left for a keeper to auction.
        _setPrice(NVDA_PRICE_8);
        vm.prank(keeper);
        vm.expectRevert(LiquidationAuction.NotLiquidatable.selector);
        auction.startAuction(loanId);
    }

    function test_repayRefusesZeroAmount() public {
        uint256 loanId = _originateExample();
        vm.prank(borrower);
        vm.expectRevert(ICreditHub.ZeroAmount.selector);
        hub.repay(loanId, 0);
    }

    /// @dev Mirrors the hub's accrual: principal times rate in bps times seconds elapsed, divided by a 365-day
    ///      year expressed in bps-seconds.
    function _interestFor(uint256 principal, uint256 aprBps, uint256 elapsed) internal pure returns (uint256) {
        return principal * aprBps * elapsed / (10_000 * 365 days);
    }
}
