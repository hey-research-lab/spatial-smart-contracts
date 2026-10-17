// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {LoanTypes} from "../src/libraries/LoanTypes.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
import {ICreditHub} from "../src/interfaces/ICreditHub.sol";

/// @notice Tests for the liquidation auction and the price checks the guard runs underneath it. Covered here:
///         the conditions that let a sale open, the descending price curve, how proceeds and the penalty are
///         shared out, partial fills and restarts, floors and lender opt-outs while the market is shut, payment
///         in collateral, Data Streams reports, and the protections for stale prices, pauses, sharp moves and
///         sequencer outages.
contract LiquidationAuctionTest is BaseTest {
    // =========================================================================
    // When a loan may be sold
    // =========================================================================

    function test_cannotLiquidateHealthyLoan() public {
        uint256 loanId = _originateExample();
        vm.prank(keeper);
        vm.expectRevert(LiquidationAuction.NotLiquidatable.selector);
        auction.startAuction(loanId);
    }

    function test_healthFactorTracksPrice() public {
        uint256 loanId = _originateExample();
        _setPrice(125_00_000_000); // 250 NVDA at 125 is 31,250 of collateral, a health factor near 1.093 (warning zone)
        (uint256 p, uint256 i) = hub.debtOf(loanId);
        assertEq(hub.healthFactor(loanId), 31_250e6 * 7000 * 1e18 / (10_000 * (p + i)));
        assertLt(hub.healthFactor(loanId), 1.1e18);
        _setPrice(114_00_000_000); // roughly 0.997, which is under one and therefore liquidatable
        assertLt(hub.healthFactor(loanId), 1e18);
    }

    function test_defaultAfterGraceIsLiquidatableAtAnyPrice() public {
        uint256 loanId = _originateExample();
        vm.warp(block.timestamp + 31 days + 1);
        _setPrice(NVDA_PRICE_8); // unchanged price, so the health factor alone would leave this loan well clear
        assertTrue(auction.isPastGrace(loanId));
        vm.prank(keeper);
        auction.startAuction(loanId);
        assertEq(uint8(hub.getLoan(loanId).status), uint8(LoanTypes.LoanStatus.Liquidating));
    }

    function test_liquidationsPausedByGuardian() public {
        uint256 loanId = _originateExample();
        _setPrice(114_00_000_000);
        vm.prank(guardian);
        riskConfig.setPaused(false, true);
        vm.prank(keeper);
        vm.expectRevert(LiquidationAuction.LiquidationsPaused.selector);
        auction.startAuction(loanId);
    }

    // =========================================================================
    // Price curve, buying and settlement
    // =========================================================================

    function test_dutchAuctionFullFlow() public {
        uint256 loanId = _originateExample();
        vm.warp(block.timestamp + 10 days);
        _setPrice(114_00_000_000);

        vm.prank(keeper);
        auction.startAuction(loanId);
        (,, uint128 startPrice, uint128 floorPrice, uint128 target,,,, bool active) = auction.auctions(loanId);
        assertTrue(active);
        assertEq(startPrice, 114_000_000 * 103 / 100); // guard price marked up 3 percent, in USDG units
        assertEq(floorPrice, 114_000_000 * 70 / 100);
        (uint256 p, uint256 i) = hub.debtOf(loanId);
        assertEq(target, (p + i) * 103 / 100);
        assertEq(uint8(hub.getLoan(loanId).status), uint8(LoanTypes.LoanStatus.Liquidating));

        // Price falls in a straight line, so at the 22.5 minute mark of a 45 minute sale it sits midway.
        vm.warp(block.timestamp + 22 minutes + 30 seconds);
        assertEq(auction.currentPrice(loanId), (uint256(startPrice) + floorPrice) / 2);

        uint256 borrowerUsdgBefore = usdg.balanceOf(borrower);
        uint256 keeperBefore = usdg.balanceOf(keeper);
        uint256 l1Before = usdg.balanceOf(lender1);
        // Interest has been running while the sale was open, so take a new reading of the debt before buying.
        (p, i) = hub.debtOf(loanId);

        // Asking for the whole 250 NVDA is fine; the sale hands over only what is needed to hit the target.
        vm.prank(liquidator);
        auction.buy(loanId, 250e18, "");

        LoanTypes.Loan memory L = hub.getLoan(loanId);
        assertEq(uint8(L.status), uint8(LoanTypes.LoanStatus.Settled));
        assertEq(L.collateralAmount, 0);
        (,,,,,,,, active) = auction.auctions(loanId);
        assertFalse(active);

        // A 3 percent penalty is charged on the debt, and the keeper is paid 3,334 bps of it.
        uint256 penalty = (p + i) * 300 / 10_000;
        assertEq(usdg.balanceOf(keeper) - keeperBefore, penalty * 3334 / 10_000);
        // lender1 recovers its principal, its interest after the protocol cut, and a slice of the penalty.
        assertGt(usdg.balanceOf(lender1) - l1Before, 5_000e6);
        // The sale raised precisely the target, so there is no USDG left over and the remaining NVDA goes home.
        assertEq(usdg.balanceOf(borrower), borrowerUsdgBefore);
        assertGt(nvda.balanceOf(borrower), 750e18);
        assertEq(hub.exposure(address(nvda)), 0);
        assertEq(nvda.balanceOf(address(hub)), 0);
    }

    /// previewBuy should report exactly the amount and cost a real buy produces, trimming to the target included.
    function test_previewBuyMatchesTheBuy() public {
        uint256 loanId = _originateExample();
        vm.warp(block.timestamp + 10 days);
        _setPrice(114_00_000_000);
        vm.prank(keeper);
        auction.startAuction(loanId);
        vm.warp(block.timestamp + 10 minutes);

        (uint256 amount, uint256 cost, uint256 price) = auction.previewBuy(loanId, 250e18);
        assertEq(price, auction.currentPrice(loanId));
        assertLt(amount, 250e18, "preview trims the amount down to what the target needs");

        uint256 nvdaBefore = nvda.balanceOf(liquidator);
        uint256 usdgBefore = usdg.balanceOf(liquidator);
        vm.prank(liquidator);
        auction.buy(loanId, 250e18, "");
        assertEq(nvda.balanceOf(liquidator) - nvdaBefore, amount);
        assertEq(usdgBefore - usdg.balanceOf(liquidator), cost);
    }

    function test_previewBuyRevertsWithNoAuction() public {
        uint256 loanId = _originateExample();
        vm.expectRevert(LiquidationAuction.AuctionNotActive.selector);
        auction.previewBuy(loanId, 1e18);
    }

    function test_buyWithLimitRefusesAPriceAboveTheLimit() public {
        uint256 loanId = _originateExample();
        vm.warp(block.timestamp + 10 days);
        _setPrice(114_00_000_000);
        vm.prank(keeper);
        auction.startAuction(loanId);
        vm.warp(block.timestamp + 10 minutes);

        uint256 price = auction.currentPrice(loanId);
        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.PriceAboveLimit.selector, price, price - 1));
        auction.buyWithLimit(loanId, 50e18, price - 1, "");

        uint256 before = nvda.balanceOf(liquidator);
        vm.prank(liquidator);
        auction.buyWithLimit(loanId, 50e18, price, "");
        assertEq(nvda.balanceOf(liquidator) - before, 50e18);
    }

    function test_endsAtIsWhenThePriceReachesTheFloor() public {
        uint256 loanId = _originateExample();
        vm.expectRevert(LiquidationAuction.AuctionNotActive.selector);
        auction.endsAt(loanId);

        vm.warp(block.timestamp + 10 days);
        _setPrice(114_00_000_000);
        vm.prank(keeper);
        auction.startAuction(loanId);
        uint256 end = auction.endsAt(loanId);
        assertEq(end, block.timestamp + riskConfig.auctionParams().duration);

        (,,, uint128 floorPrice,,,,,) = auction.auctions(loanId);
        vm.warp(end);
        assertEq(auction.currentPrice(loanId), floorPrice);
    }

    function test_isActiveFollowsTheAuction() public {
        uint256 loanId = _originateExample();
        assertFalse(auction.isActive(loanId));
        vm.warp(block.timestamp + 10 days);
        _setPrice(114_00_000_000);
        vm.prank(keeper);
        auction.startAuction(loanId);
        assertTrue(auction.isActive(loanId));
        vm.prank(liquidator);
        auction.buy(loanId, 250e18, "");
        assertFalse(auction.isActive(loanId), "no longer active once the loan has settled");
    }

    /// A 50 NVDA fill keeps the sale running and records its proceeds; a 200 NVDA fill then finishes it.
    function test_partialBuysAccumulate() public {
        uint256 loanId = _originateExample();
        vm.warp(block.timestamp + 2 hours); // step past the hour in which the move cap compares prices
        _setPrice(114_00_000_000);
        vm.prank(keeper);
        auction.startAuction(loanId);
        vm.prank(liquidator);
        auction.buy(loanId, 50e18, "");
        (,,,,, uint128 proceeds,,, bool active) = auction.auctions(loanId);
        assertTrue(active);
        assertGt(proceeds, 0);
        assertEq(hub.getLoan(loanId).collateralAmount, 200e18);
        vm.prank(liquidator);
        auction.buy(loanId, 200e18, "");
        (,,,,,,,, active) = auction.auctions(loanId);
        assertFalse(active);
    }

    function test_buyRequiresLiquidatorRole() public {
        uint256 loanId = _originateExample();
        vm.warp(block.timestamp + 2 hours); // step past the hour in which the move cap compares prices
        _setPrice(114_00_000_000);
        vm.prank(keeper);
        auction.startAuction(loanId);
        vm.prank(lender1);
        vm.expectRevert();
        auction.buy(loanId, 10e18, "");
    }

    /// Pausing liquidations must also halt a sale already under way. If it only blocked new ones, a guardian
    /// reacting to a bad price would still see collateral sold along the curve that bad price set.
    function test_pauseStopsAnAuctionThatIsAlreadyRunning() public {
        uint256 loanId = _originateExample();
        vm.warp(block.timestamp + 2 hours);
        _setPrice(114_00_000_000);
        vm.prank(keeper);
        auction.startAuction(loanId);

        vm.prank(liquidator);
        auction.buy(loanId, 10e18, "");

        vm.prank(guardian);
        riskConfig.setPaused(false, true);
        vm.prank(liquidator);
        vm.expectRevert(LiquidationAuction.LiquidationsPaused.selector);
        auction.buy(loanId, 10e18, "");

        // Once the pause is cleared buying works again, and a restart could reset any price decay that happened
        // meanwhile. Clearing is the owner's job, since the guardian can only switch pauses on.
        vm.prank(gov);
        riskConfig.setPaused(false, false);
        vm.prank(liquidator);
        auction.buy(loanId, 10e18, "");
        assertEq(uint8(hub.getLoan(loanId).status), uint8(LoanTypes.LoanStatus.Liquidating));
    }

    // =========================================================================
    // Closed market, opt-outs and payment in collateral
    // =========================================================================

    function test_closedMarketHaircutLowersHealthFactor() public {
        uint256 loanId = _originateExample();
        uint256 hfOpen = hub.healthFactor(loanId);
        nvda.setMarketStatus(5);
        uint256 hfClosed = hub.healthFactor(loanId);
        // Outside trading hours a 10 point haircut applies, so 70 percent liquidation LTV becomes 60 percent.
        assertApproxEqAbs(hfClosed * 70 / 60, hfOpen, 1e12);
    }

    function test_closedMarketLiquidationUsesBoundedFloorAndExcludesOptOuts() public {
        // The middle offer, from lender2, sets the flag that forbids selling while the market is shut.
        LoanTypes.LendOffer[] memory offers = new LoanTypes.LendOffer[](3);
        bytes[] memory sigs = new bytes[](3);
        offers[0] = _offer(lender1, 5_000e6, 850, 1, 0);
        offers[1] = _offer(lender2, 10_000e6, 890, 1, LoanTypes.FLAG_NO_CLOSED_MARKET_LIQUIDATION);
        offers[2] = _offer(lender3, 5_000e6, 900, 1, 0);
        sigs[0] = _sign(lender1Pk, offers[0]);
        sigs[1] = _sign(lender2Pk, offers[1]);
        sigs[2] = _sign(lender3Pk, offers[2]);
        vm.prank(borrower);
        uint256 loanId = hub.originate(_request(250e18, 20_000e6, 900), "", offers, sigs);

        vm.warp(block.timestamp + 2 hours); // step past the hour in which the move cap compares prices
        nvda.setMarketStatus(5);
        _setPrice(130_00_000_000); // closed-market LTV of 60 percent: 32,500 times 0.60 over 20,014 gives about 0.975
        assertLt(hub.healthFactor(loanId), 1e18);

        vm.prank(keeper);
        auction.startAuction(loanId);

        // lender2's slice was carved out into a fresh Active loan that takes its proportional half of the NVDA.
        uint256 newLoanId = hub.loanCount();
        LoanTypes.Loan memory kept = hub.getLoan(newLoanId);
        assertEq(uint8(kept.status), uint8(LoanTypes.LoanStatus.Active));
        assertEq(kept.principal, 10_000e6);
        assertEq(kept.collateralAmount, 125e18);
        assertEq(kept.sliceIds.length, 1);
        assertEq(hub.getSlice(kept.sliceIds[0]).lender, lender2);

        // What remains on the first loan goes to auction, floored at 85 percent because the market is closed.
        LoanTypes.Loan memory sold = hub.getLoan(loanId);
        assertEq(sold.principal, 10_000e6);
        assertEq(sold.collateralAmount, 125e18);
        (,,, uint128 floorPrice,,,,,) = auction.auctions(loanId);
        assertEq(floorPrice, 130_000_000 * 85 / 100);
    }

    /// When the only slice has opted out of selling in a closed market, no collateral is left to offer and the
    /// start is refused.
    function test_closedMarketAllOptOutReverts() public {
        LoanTypes.LendOffer[] memory offers = new LoanTypes.LendOffer[](1);
        bytes[] memory sigs = new bytes[](1);
        offers[0] = _offer(lender1, 20_000e6, 850, 1, LoanTypes.FLAG_NO_CLOSED_MARKET_LIQUIDATION);
        sigs[0] = _sign(lender1Pk, offers[0]);
        vm.prank(borrower);
        uint256 loanId = hub.originate(_request(250e18, 20_000e6, 900), "", offers, sigs);
        vm.warp(block.timestamp + 2 hours); // step past the hour in which the move cap compares prices
        nvda.setMarketStatus(5);
        _setPrice(130_00_000_000);
        vm.prank(keeper);
        vm.expectRevert(LiquidationAuction.NoClosedMarketLiquidation.selector);
        auction.startAuction(loanId);
    }

    function test_quietFeedIsAcceptedWhileTheMarketIsClosed() public {
        uint256 loanId = _originateExample();
        vm.warp(block.timestamp + 10 days);
        _setPrice(130_00_000_000);
        nvda.setMarketStatus(5);
        // After the close the feed goes silent for twelve hours. Closed sessions tolerate prices up to four days
        // old, so the quote is still good, and the sale leans on the haircut and the raised floor for safety.
        vm.warp(block.timestamp + 12 hours);
        assertFalse(guard.quote(address(nvda)).stale);
        assertLt(hub.healthFactor(loanId), 1e18);
        vm.prank(keeper);
        auction.startAuction(loanId);
        assertEq(uint8(hub.getLoan(loanId).status), uint8(LoanTypes.LoanStatus.Liquidating));
    }

    function test_inKindLiquidationPaysLenderInCollateral() public {
        LoanTypes.LendOffer[] memory offers = new LoanTypes.LendOffer[](2);
        bytes[] memory sigs = new bytes[](2);
        offers[0] = _offer(lender1, 10_000e6, 850, 1, LoanTypes.FLAG_SELF_LIQUIDATE);
        offers[1] = _offer(lender2, 10_000e6, 890, 1, 0);
        sigs[0] = _sign(lender1Pk, offers[0]);
        sigs[1] = _sign(lender2Pk, offers[1]);
        vm.prank(borrower);
        uint256 loanId = hub.originate(_request(250e18, 20_000e6, 900), "", offers, sigs);

        vm.warp(block.timestamp + 2 hours); // step past the hour in which the move cap compares prices
        _setPrice(114_00_000_000);
        uint256 nvdaBefore = nvda.balanceOf(lender1);
        vm.prank(keeper);
        auction.startAuction(loanId);

        // lender1 was paid in NVDA at 114.00 a share, never more than its proportional 125 NVDA.
        uint256 received = nvda.balanceOf(lender1) - nvdaBefore;
        assertGt(received, 0);
        assertLe(received, 125e18);
        LoanTypes.Loan memory L = hub.getLoan(loanId);
        assertEq(L.sliceIds.length, 1);
        assertEq(L.principal, 10_000e6);
        assertEq(hub.getSlice(L.sliceIds[0]).lender, lender2);
    }

    // =========================================================================
    // Price protections
    // =========================================================================

    /// Once NVDA has a Data Streams adapter, every buy has to carry a report, and that report is compared with
    /// the feed.
    function test_streamReportRequiredWhenConfigured() public {
        vm.prank(gov);
        guard.configureFeed(
            address(nvda),
            address(usdg),
            nvdaFeed,
            1 hours,
            2 hours,
            4 days,
            2500,
            1 hours,
            200,
            address(nvda),
            address(nvda),
            address(nvda),
            address(stream)
        );
        uint256 loanId = _originateExample();
        vm.warp(block.timestamp + 2 hours); // step past the hour in which the move cap compares prices
        _setPrice(114_00_000_000);
        stream.set(114_00_000_000);
        vm.prank(keeper);
        auction.startAuction(loanId);
        vm.prank(liquidator);
        vm.expectRevert(LiquidationAuction.StreamReportRequired.selector);
        auction.buy(loanId, 10e18, "");
        vm.prank(liquidator);
        auction.buy(loanId, 10e18, hex"01");
        // Push the report well away from the feed, past the 200 bps tolerance, and the buy fails.
        stream.set(150_00_000_000);
        vm.prank(liquidator);
        vm.expectRevert();
        auction.buy(loanId, 10e18, hex"01");
    }

    function test_sequencerGraceBlocksLiquidation() public {
        uint256 loanId = _originateExample();
        vm.warp(block.timestamp + 2 hours); // step past the hour in which the move cap compares prices
        _setPrice(114_00_000_000);
        sequencer.setWithTimestamps(0, block.timestamp - 10 minutes, block.timestamp);
        vm.prank(keeper);
        vm.expectRevert(LiquidationAuction.SequencerGrace.selector);
        auction.startAuction(loanId);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(keeper);
        auction.startAuction(loanId);
    }

    /// Flipping the token's oracle pause prevents a sale from starting. Origination is covered elsewhere; this
    /// case looks only at liquidation.
    function test_oraclePauseBlocksLiquidationAndOrigination() public {
        uint256 loanId = _originateExample();
        _setPrice(114_00_000_000);
        nvda.setOraclePaused(true);
        vm.prank(keeper);
        vm.expectRevert(LiquidationAuction.GuardPaused.selector);
        auction.startAuction(loanId);
    }

    function test_staleFeedBlocksLiquidationDuringTradingHours() public {
        uint256 loanId = _originateExample();
        vm.warp(block.timestamp + 10 days);
        _setPrice(114_00_000_000);
        // Let two hours pass in the regular session with no new price; the limit there is one hour.
        vm.warp(block.timestamp + 2 hours);
        assertTrue(guard.quote(address(nvda)).stale);
        assertLt(hub.healthFactor(loanId), 1e18);
        vm.prank(keeper);
        vm.expectRevert(LiquidationAuction.OracleStale.selector);
        auction.startAuction(loanId);
        assertEq(uint8(hub.getLoan(loanId).status), uint8(LoanTypes.LoanStatus.Active));

        // Restarting asks the guard for a price again, so an old price stops that too.
        _setPrice(114_00_000_000);
        vm.prank(keeper);
        auction.startAuction(loanId);
        (, uint32 duration,,,,,,,) = auction.auctions(loanId);
        vm.warp(block.timestamp + duration + 1 hours);
        vm.prank(keeper);
        vm.expectRevert(LiquidationAuction.OracleStale.selector);
        auction.restart(loanId);
        _setPrice(114_00_000_000);
        vm.prank(keeper);
        auction.restart(loanId);
    }

    function test_moveCapPausesMarket() public {
        _originateExample(); // opening the loan records a 176.40 reference price in the guard
        _setPrice(100_00_000_000); // a 43 percent fall from a reference taken in this same block; the cap is 25
        guard.refresh(address(nvda));
        assertTrue(guard.quote(address(nvda)).paused);
        LoanTypes.LendOffer[] memory offers = new LoanTypes.LendOffer[](1);
        bytes[] memory sigs = new bytes[](1);
        offers[0] = _offer(lender1, 10_000e6, 850, 5, 0);
        sigs[0] = _sign(lender1Pk, offers[0]);
        LoanTypes.BorrowRequest memory r = _request(250e18, 10_000e6, 900);
        r.salt = bytes32(uint256(9));
        vm.prank(borrower);
        vm.expectRevert(ICreditHub.OracleUnusable.selector);
        hub.originate(r, "", offers, sigs);
        vm.prank(gov);
        guard.resume(address(nvda));
        assertFalse(guard.quote(address(nvda)).paused);
    }

    function test_moveCapIgnoresAStaleCheckpoint() public {
        _originateExample(); // reference price of 176.40, written when the loan opened
        assertEq(guard.checkpoint(address(nvda)).lastAt, block.timestamp);

        // Same 43 percent drop, only now the reference is a full day old. Over that span the guard treats the
        // change as gradual and simply adopts the new price as its reference rather than pausing.
        vm.warp(block.timestamp + 1 days);
        _setPrice(100_00_000_000);
        guard.refresh(address(nvda));
        assertFalse(guard.quote(address(nvda)).paused);
        assertEq(guard.checkpoint(address(nvda)).lastPrice, 100_000_000, "reference moved to the new price");
        assertEq(guard.checkpoint(address(nvda)).lastAt, block.timestamp);

        // A similar drop measured against that brand new reference does pause the market.
        _setPrice(60_00_000_000);
        guard.refresh(address(nvda));
        assertTrue(guard.quote(address(nvda)).paused);
        assertEq(guard.checkpoint(address(nvda)).lastPrice, 100_000_000, "reference stays at the last trusted price");
    }

    function test_moveCapStillFiresAtTheEdgeOfItsWindow() public {
        _originateExample();
        vm.warp(block.timestamp + 1 hours); // the window includes its end point, so a gap of exactly an hour counts
        _setPrice(100_00_000_000);
        guard.refresh(address(nvda));
        assertTrue(guard.quote(address(nvda)).paused);
    }

    function test_liquidationRefusesAPriceThatGappedPastTheMoveCap() public {
        uint256 loanId = _originateExample(); // reference of 176.40 from the origination
        _setPrice(114_00_000_000); // a single update 35 percent under that reference

        // On paper the loan is below water. Yet a lone jump beyond the move cap is the very thing the cap is
        // meant to treat with suspicion, so it cannot be the basis for a forced sale.
        assertLt(hub.healthFactor(loanId), 1e18);
        vm.prank(keeper);
        vm.expectRevert(LiquidationAuction.GuardPaused.selector);
        auction.startAuction(loanId);
        assertEq(uint8(hub.getLoan(loanId).status), uint8(LoanTypes.LoanStatus.Active));

        // Because startAuction reverted, its write to the reference was undone too. Anyone can call refresh(),
        // though, which sets the pause and leaves the price for governance to look at.
        guard.refresh(address(nvda));
        assertTrue(guard.quote(address(nvda)).paused);
        vm.prank(gov);
        guard.resume(address(nvda));

        // After two hours the reference has aged out of the window, the same price counts as a normal move, and
        // the sale can begin.
        vm.warp(block.timestamp + 2 hours);
        _setPrice(114_00_000_000);
        vm.prank(keeper);
        auction.startAuction(loanId);
        assertEq(uint8(hub.getLoan(loanId).status), uint8(LoanTypes.LoanStatus.Liquidating));
    }

    function test_startingAnAuctionCheckpointsThePrice() public {
        uint256 loanId = _originateExample();
        assertEq(guard.checkpoint(address(nvda)).lastPrice, 176_400_000);

        vm.warp(block.timestamp + 10 days);
        _setPrice(114_00_000_000);
        vm.prank(keeper);
        auction.startAuction(loanId);

        // Opening the sale writes a new reference, so later move-cap checks measure from the auction's starting
        // price and not from the price seen at origination.
        assertEq(guard.checkpoint(address(nvda)).lastPrice, 114_000_000);
        assertEq(guard.checkpoint(address(nvda)).lastAt, block.timestamp);
    }

    // =========================================================================
    // Restarting a stalled sale
    // =========================================================================

    function test_stalledAuctionCanBeRestartedAtTheCurrentPrice() public {
        uint256 loanId = _originateExample();
        vm.warp(block.timestamp + 10 days);
        _setPrice(114_00_000_000);

        vm.prank(keeper);
        auction.startAuction(loanId);
        (, uint32 duration,, uint128 floorPrice,,,,,) = auction.auctions(loanId);

        // While the curve still has time left, restart is not allowed.
        vm.prank(keeper);
        vm.expectRevert(LiquidationAuction.AuctionNotEnded.selector);
        auction.restart(loanId);

        // No buyer turned up. The price has reached its floor and the loan sits in Liquidating, a status in which
        // the hub turns away repayments and the collateral stays locked.
        vm.warp(block.timestamp + duration + 1);
        assertEq(auction.currentPrice(loanId), floorPrice);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(ICreditHub.BadStatus.selector, LoanTypes.LoanStatus.Liquidating));
        hub.repay(loanId, 1_000e6);

        // NVDA has dropped further. A restart, open to any caller, rebuilds the curve from today's guard price
        // and today's debt.
        _setPrice(90_00_000_000);
        (uint256 p, uint256 i) = hub.debtOf(loanId);
        vm.prank(keeper);
        auction.restart(loanId);

        uint128 newStart;
        uint128 newFloor;
        uint128 newTarget;
        (,, newStart, newFloor, newTarget,,,,) = auction.auctions(loanId);
        assertEq(newStart, 90_000_000 * 103 / 100);
        assertEq(newFloor, 90_000_000 * 70 / 100);
        assertEq(newTarget, (p + i) * 103 / 100);
        assertEq(auction.currentPrice(loanId), newStart);
        assertEq(uint8(hub.getLoan(loanId).status), uint8(LoanTypes.LoanStatus.Liquidating));

        // On the new curve a buyer appears and the loan closes out.
        vm.warp(block.timestamp + 30 minutes);
        vm.prank(liquidator);
        auction.buy(loanId, 250e18, "");
        assertEq(uint8(hub.getLoan(loanId).status), uint8(LoanTypes.LoanStatus.Settled));
        assertEq(hub.exposure(address(nvda)), 0);
    }

    function test_restartKeepsProceedsFromTheStalledRound() public {
        uint256 loanId = _originateExample();
        vm.warp(block.timestamp + 10 days);
        _setPrice(114_00_000_000);
        vm.prank(keeper);
        auction.startAuction(loanId);

        vm.warp(block.timestamp + 20 minutes);
        vm.prank(liquidator);
        auction.buy(loanId, 50e18, "");
        (,,,,, uint128 proceeds,,,) = auction.auctions(loanId);
        assertGt(proceeds, 0);

        vm.warp(block.timestamp + 45 minutes);
        _setPrice(114_00_000_000);
        vm.prank(keeper);
        auction.restart(loanId);
        uint128 proceedsAfter;
        (,,,,, proceedsAfter,,,) = auction.auctions(loanId);
        assertEq(proceedsAfter, proceeds, "money raised in the first round carries over after a restart");
    }

    function test_timeRemainingCountsDownToTheFloor() public {
        uint256 loanId = _originateExample();
        vm.expectRevert(LiquidationAuction.AuctionNotActive.selector);
        auction.timeRemaining(loanId);

        vm.warp(block.timestamp + 10 days);
        _setPrice(114_00_000_000);
        vm.prank(keeper);
        auction.startAuction(loanId);
        uint256 duration = riskConfig.auctionParams().duration;
        assertEq(auction.timeRemaining(loanId), duration);

        vm.warp(block.timestamp + 10 minutes);
        assertEq(auction.timeRemaining(loanId), duration - 10 minutes);

        vm.warp(auction.endsAt(loanId) + 1);
        assertEq(auction.timeRemaining(loanId), 0);
    }
}
