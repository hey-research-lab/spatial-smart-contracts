// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {LoanTypes} from "../src/libraries/LoanTypes.sol";
import {QuoteHash} from "../src/libraries/QuoteHash.sol";
import {RolloverMarket} from "../src/RolloverMarket.sol";
import {ICreditHub} from "../src/interfaces/ICreditHub.sol";
import {IRiskConfig} from "../src/interfaces/IRiskConfig.sol";

/// @notice Tests for the rollover market. They check who can start a rollover and at what point, how the offered
///         rate climbs from the loan's weighted APR up to its ceiling, refinancing into a new group of lenders,
///         expiry into default, withdrawal by the borrower, refunds when a liquidation interrupts, and the limit
///         on how many offers can be taken.
contract RolloverMarketTest is BaseTest {
    // =========================================================================
    // Opening and the rate curve
    // =========================================================================

    /// Started on day 27, the rollover begins at the loan's 882 bps weighted rate and tops out 400 bps higher.
    function test_openRefinanceOnlyByBorrowerBeforeMaturity() public {
        uint256 loanId = _originateExample();
        vm.prank(lender1);
        vm.expectRevert(ICreditHub.NotBorrower.selector);
        rollover.openRefinance(loanId);

        vm.warp(block.timestamp + 27 days);
        vm.prank(borrower);
        rollover.openRefinance(loanId);
        (,, uint16 startRate, uint16 capRate,, bool active) = rollover.rollovers(loanId);
        assertTrue(active);
        assertEq(startRate, 882);
        assertEq(capRate, 1282);
        assertEq(uint8(hub.getLoan(loanId).status), uint8(LoanTypes.LoanStatus.Refinancing));
    }

    function test_rateRisesLinearlyToCap() public {
        uint256 loanId = _originateExample();
        vm.prank(borrower);
        rollover.openRefinance(loanId);
        assertEq(rollover.currentRate(loanId), 882);
        vm.warp(block.timestamp + 2 hours);
        assertEq(rollover.currentRate(loanId), 1082);
        vm.warp(block.timestamp + 3 hours);
        assertEq(rollover.currentRate(loanId), 1282);
    }

    function test_endsAtMatchesTheWindow() public {
        uint256 loanId = _originateExample();
        vm.expectRevert(RolloverMarket.NotActive.selector);
        rollover.endsAt(loanId);

        vm.warp(block.timestamp + 27 days);
        vm.prank(borrower);
        rollover.openRefinance(loanId);
        uint256 end = rollover.endsAt(loanId);
        assertEq(end, block.timestamp + riskConfig.refinanceParams().duration);

        vm.warp(end);
        vm.expectRevert(RolloverMarket.AuctionNotEnded.selector);
        rollover.fail(loanId);
        vm.warp(end + 1);
        rollover.fail(loanId);
    }

    function test_isActiveFollowsTheRollover() public {
        uint256 loanId = _originateExample();
        assertFalse(rollover.isActive(loanId));
        vm.warp(block.timestamp + 27 days);
        vm.prank(borrower);
        rollover.openRefinance(loanId);
        assertTrue(rollover.isActive(loanId));
        vm.prank(borrower);
        rollover.cancelRefinance(loanId);
        assertFalse(rollover.isActive(loanId));
    }

    // =========================================================================
    // Taking offers and clearing
    // =========================================================================

    function test_rolloverClearsWithNewSyndicate() public {
        uint256 loanId = _originateExample();
        vm.warp(block.timestamp + 27 days);
        vm.prank(borrower);
        rollover.openRefinance(loanId);
        vm.warp(block.timestamp + 40 minutes); // one sixth of the 4 hour window: 882 plus 400 * 40 / 240 makes 948 bps

        (uint256 total, uint256 fee) = rollover.target(loanId);
        uint256 l1Before = usdg.balanceOf(lender1);
        uint256 l2Before = usdg.balanceOf(lender2);
        uint256 feeVaultBefore = usdg.balanceOf(address(feeVault));
        uint256 oldSlice1 = hub.getLoan(loanId).sliceIds[0];

        // lender1 rolls into the same loan through an offer tied to this rollover, and lender2 fills the rest.
        LoanTypes.LendOffer memory o1 = _offer(lender1, 10_000e6, 900, 11, 0);
        o1.requestId = QuoteHash.rolloverKey(loanId);
        bytes memory s1 = _sign(lender1Pk, o1);
        vm.prank(keeper);
        rollover.accept(loanId, o1, s1);
        (,,,, uint128 accepted, bool active) = rollover.rollovers(loanId);
        assertTrue(active);
        assertEq(accepted, 10_000e6);

        LoanTypes.LendOffer memory o2 = _offer(lender2, 50_000e6, 940, 12, 0);
        bytes memory s2 = _sign(lender2Pk, o2);
        (, uint256 oldInterest) = hub.debtOf(loanId);
        vm.prank(keeper);
        rollover.accept(loanId, o2, s2);

        (,,,, accepted, active) = rollover.rollovers(loanId);
        assertFalse(active);
        LoanTypes.Loan memory L = hub.getLoan(loanId);
        assertEq(uint8(L.status), uint8(LoanTypes.LoanStatus.Active));
        assertEq(L.principal, total, "principal after rollover is the old debt plus the fee");
        assertEq(L.maturity, block.timestamp + 30 days, "maturity restarts with a full term");
        assertEq(L.sliceIds.length, 2);
        assertEq(hub.getSlice(L.sliceIds[0]).aprBps, 948);
        assertEq(hub.getSlice(L.sliceIds[1]).aprBps, 948);
        assertEq(L.collateralAmount, 250e18, "the NVDA stayed where it was");

        // The previous slices were repaid. lender2 got its earlier 10,000 plus interest back before funding the
        // remainder.
        assertGt(usdg.balanceOf(lender1) + 10_000e6, l1Before + 5_000e6);
        assertGt(usdg.balanceOf(lender2) + (total - 10_000e6), l2Before + 10_000e6);
        assertApproxEqAbs(
            usdg.balanceOf(address(feeVault)) - feeVaultBefore,
            fee + oldInterest * 1000 / 10_000,
            3,
            "fee vault gets the rollover fee and its cut of interest"
        );
        vm.expectRevert();
        sliceNote.ownerOf(oldSlice1);
        assertEq(usdg.balanceOf(address(rollover)), 0, "the rollover market keeps no USDG once cleared");
    }

    /// When a rollover clears, the fill stays recorded, since that capacity really was turned into a slice.
    function test_clearedRolloverKeepsTheFillBooked() public {
        uint256 loanId = _originateExample();
        vm.warp(block.timestamp + 27 days);
        vm.prank(borrower);
        rollover.openRefinance(loanId);

        (uint256 total,) = rollover.target(loanId);
        LoanTypes.LendOffer memory o = _offer(lender1, 40_000e6, 882, 21, 0);
        o.termSeconds = TERM_30D;
        bytes memory sig = _sign(lender1Pk, o);
        vm.prank(keeper);
        rollover.accept(loanId, o, sig);

        assertEq(hub.filled(_offerDigest(o)), total, "the full target was taken from the offer and stays taken");
        assertEq(hub.remainingCapacity(o), 40_000e6 - total);
    }

    function test_shortfallTracksAcceptances() public {
        uint256 loanId = _originateExample();
        vm.expectRevert(RolloverMarket.NotActive.selector);
        rollover.shortfall(loanId);

        vm.warp(block.timestamp + 27 days);
        vm.prank(borrower);
        rollover.openRefinance(loanId);
        vm.warp(block.timestamp + 40 minutes);
        (uint256 total,) = rollover.target(loanId);
        assertEq(rollover.shortfall(loanId), total);

        LoanTypes.LendOffer memory o1 = _offer(lender1, 10_000e6, 900, 11, 0);
        o1.requestId = QuoteHash.rolloverKey(loanId);
        bytes memory s1 = _sign(lender1Pk, o1);
        vm.prank(keeper);
        rollover.accept(loanId, o1, s1);
        assertEq(rollover.shortfall(loanId), total - 10_000e6);
    }

    function test_offerAboveCurrentRateRejected() public {
        uint256 loanId = _originateExample();
        vm.prank(borrower);
        rollover.openRefinance(loanId);
        LoanTypes.LendOffer memory o1 = _offer(lender1, 5_000e6, 1000, 11, 0);
        bytes memory s1 = _sign(lender1Pk, o1);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(RolloverMarket.RateTooHigh.selector, 1000, 882));
        rollover.accept(loanId, o1, s1);
    }

    function test_acceptanceCapMatchesTheSliceCap() public {
        uint256 loanId = _originateExample();
        vm.prank(gov);
        riskConfig.setLoanParams(
            IRiskConfig.LoanParams({
                minInterestPeriod: 3 days, graceWindow: 24 hours, sequencerGrace: 1 hours, maxSlicesPerLoan: 1
            })
        );
        vm.prank(borrower);
        rollover.openRefinance(loanId);

        LoanTypes.LendOffer memory o1 = _offer(lender1, 5_000e6, 880, 21, 0);
        bytes memory s1 = _sign(lender1Pk, o1);
        vm.prank(keeper);
        rollover.accept(loanId, o1, s1);

        // Loans are limited to a single slice here, so taking another offer would produce a loan the hub could
        // not mint notes for.
        LoanTypes.LendOffer memory o2 = _offer(lender2, 50_000e6, 880, 22, 0);
        bytes memory s2 = _sign(lender2Pk, o2);
        vm.prank(keeper);
        vm.expectRevert(RolloverMarket.TooManyAcceptances.selector);
        rollover.accept(loanId, o2, s2);
    }

    // =========================================================================
    // Expiry and default
    // =========================================================================

    function test_rolloverFailsAtCapAndDefaults() public {
        uint256 loanId = _originateExample();
        vm.prank(borrower);
        rollover.openRefinance(loanId);
        LoanTypes.LendOffer memory o1 = _offer(lender1, 5_000e6, 880, 11, 0);
        bytes memory s1 = _sign(lender1Pk, o1);
        vm.prank(keeper);
        rollover.accept(loanId, o1, s1);
        uint256 l1Before = usdg.balanceOf(lender1);

        vm.warp(block.timestamp + 4 hours + 1);
        vm.prank(keeper);
        vm.expectRevert(RolloverMarket.AuctionEnded.selector);
        rollover.accept(loanId, o1, s1);

        rollover.fail(loanId);
        assertEq(usdg.balanceOf(lender1) - l1Before, 5_000e6, "the lender who accepted gets its money back");
        assertEq(uint8(hub.getLoan(loanId).status), uint8(LoanTypes.LoanStatus.Defaulted));

        // A defaulted loan needs no health check to be sold. After a new price update the sale starts even
        // though NVDA has not moved.
        _setPrice(NVDA_PRICE_8);
        vm.prank(keeper);
        auction.startAuction(loanId);
        assertEq(uint8(hub.getLoan(loanId).status), uint8(LoanTypes.LoanStatus.Liquidating));
    }

    /// Taking an offer records a fill on it before anyone can tell whether the rollover will succeed. A failed
    /// rollover gives the funds back, and it must release that recorded fill as well; otherwise the lender's
    /// standing offer would be left smaller because of a refinance that never happened.
    function test_failedRolloverGivesTheOfferItsCapacityBack() public {
        uint256 loanId = _originateExample();
        vm.prank(borrower);
        rollover.openRefinance(loanId);

        // 8,000 is well short of the roughly 20,000 target, so taking it does not complete the rollover.
        LoanTypes.LendOffer memory o1 = _offer(lender1, 8_000e6, 880, 11, 0);
        bytes memory s1 = _sign(lender1Pk, o1);
        assertEq(hub.remainingCapacity(o1), 8_000e6);

        vm.prank(keeper);
        rollover.accept(loanId, o1, s1);
        assertEq(hub.remainingCapacity(o1), 0, "the offer is fully tied up while the rollover is open");

        vm.warp(block.timestamp + 4 hours + 1);
        rollover.fail(loanId);
        assertEq(hub.remainingCapacity(o1), 8_000e6, "capacity is released when the funds are returned");
        assertEq(hub.filled(_offerDigest(o1)), 0);

        // To prove the capacity is genuinely usable, the same offer then funds a new loan.
        _setPrice(NVDA_PRICE_8); // the rollover window used up enough time that origination needs a newer price
        LoanTypes.LendOffer[] memory offers = new LoanTypes.LendOffer[](1);
        bytes[] memory sigs = new bytes[](1);
        offers[0] = o1;
        sigs[0] = s1;
        LoanTypes.BorrowRequest memory r = _request(250e18, 8_000e6, 900);
        r.salt = bytes32(uint256(77));
        vm.prank(borrower);
        hub.originate(r, "", offers, sigs);
        assertEq(hub.remainingCapacity(o1), 0);
    }

    // =========================================================================
    // Borrower withdrawal
    // =========================================================================

    function test_borrowerCanCancelBeforeAcceptances() public {
        uint256 loanId = _originateExample();
        vm.prank(borrower);
        rollover.openRefinance(loanId);
        vm.prank(borrower);
        rollover.cancelRefinance(loanId);
        assertEq(uint8(hub.getLoan(loanId).status), uint8(LoanTypes.LoanStatus.Active));
    }

    /// While a loan is in Refinancing the hub will not take repayments. If a borrower who already has offers
    /// taken changes their mind and wants to repay, they need a way to back out; without one they would have to
    /// sit until the window lapses, become Defaulted, and face liquidation by any keeper whatever their health.
    function test_borrowerCanCancelAfterAcceptancesAndThenRepay() public {
        uint256 loanId = _originateExample();
        vm.prank(borrower);
        rollover.openRefinance(loanId);

        LoanTypes.LendOffer memory o1 = _offer(lender1, 8_000e6, 880, 11, 0);
        bytes memory s1 = _sign(lender1Pk, o1);
        vm.prank(keeper);
        rollover.accept(loanId, o1, s1);
        uint256 l1Before = usdg.balanceOf(lender1);

        // As long as the rollover is open, repay is refused.
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(ICreditHub.BadStatus.selector, LoanTypes.LoanStatus.Refinancing));
        hub.repay(loanId, 1_000e6);

        vm.prank(borrower);
        rollover.cancelRefinance(loanId);

        assertEq(usdg.balanceOf(lender1) - l1Before, 8_000e6, "every unit the lender put in comes back");
        assertEq(hub.remainingCapacity(o1), 8_000e6, "the lender's offer is restored to full size");
        assertEq(uint8(hub.getLoan(loanId).status), uint8(LoanTypes.LoanStatus.Active));
        (,,,,, bool active) = rollover.rollovers(loanId);
        assertFalse(active);
        assertEq(rollover.acceptances(loanId).length, 0);

        // The original terms apply again, and the borrower pays the loan off.
        (uint256 p, uint256 i) = hub.debtOf(loanId);
        vm.prank(borrower);
        hub.repay(loanId, p + i);
        assertEq(uint8(hub.getLoan(loanId).status), uint8(LoanTypes.LoanStatus.Repaid));
    }

    function test_onlyTheBorrowerMayCancelARollover() public {
        uint256 loanId = _originateExample();
        vm.prank(borrower);
        rollover.openRefinance(loanId);
        vm.prank(lender1);
        vm.expectRevert(RolloverMarket.NotBorrower.selector);
        rollover.cancelRefinance(loanId);
    }

    // =========================================================================
    // Liquidation interrupting a rollover
    // =========================================================================

    /// NVDA falls while the rollover is open. Starting the liquidation ends the rollover and sends lender1 its
    /// 5,000 back.
    function test_liquidationDuringRolloverRefundsAcceptors() public {
        uint256 loanId = _originateExample();
        vm.prank(borrower);
        rollover.openRefinance(loanId);
        LoanTypes.LendOffer memory o1 = _offer(lender1, 5_000e6, 880, 11, 0);
        bytes memory s1 = _sign(lender1Pk, o1);
        vm.prank(keeper);
        rollover.accept(loanId, o1, s1);
        uint256 l1Before = usdg.balanceOf(lender1);

        vm.warp(block.timestamp + 2 hours); // step past the hour in which the move cap compares prices
        _setPrice(114_00_000_000);
        vm.prank(keeper);
        auction.startAuction(loanId);
        assertEq(usdg.balanceOf(lender1) - l1Before, 5_000e6);
        (,,,,, bool active) = rollover.rollovers(loanId);
        assertFalse(active);
        assertEq(uint8(hub.getLoan(loanId).status), uint8(LoanTypes.LoanStatus.Liquidating));
    }

    /// Fill capacity must also be released when a liquidation ends the rollover early, not only on expiry.
    function test_liquidationDuringRolloverGivesTheOfferItsCapacityBack() public {
        uint256 loanId = _originateExample();
        vm.prank(borrower);
        rollover.openRefinance(loanId);
        LoanTypes.LendOffer memory o1 = _offer(lender1, 8_000e6, 880, 11, 0);
        bytes memory s1 = _sign(lender1Pk, o1);
        vm.prank(keeper);
        rollover.accept(loanId, o1, s1);
        assertEq(hub.remainingCapacity(o1), 0);

        vm.warp(block.timestamp + 2 hours);
        _setPrice(114_00_000_000);
        vm.prank(keeper);
        auction.startAuction(loanId);
        assertEq(hub.remainingCapacity(o1), 8_000e6);
    }
}
