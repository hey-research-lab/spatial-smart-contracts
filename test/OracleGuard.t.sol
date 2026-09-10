// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {OracleGuard} from "../src/OracleGuard.sol";
import {IOracleGuard} from "../src/interfaces/IOracleGuard.sol";
import {AggregatorV3Interface} from "../src/interfaces/IExternal.sol";
import {MockERC20, MockAggregatorV3} from "../src/mocks/Mocks.sol";

/// @notice Tests for the guard: which feed settings it will store, the loan token it remembers per collateral
///         token, how it reads the sequencer uptime feed, how it vets Data Streams reports, and the prices it
///         will not hand out.
contract OracleGuardTest is BaseTest {
    // =========================================================================
    // Helpers
    // =========================================================================

    /// @dev Calls configureFeed with the fixture's values, except for the arguments exposed here, so that each
    ///      case varies a single setting.
    function _configure(
        address collateralToken,
        address loanToken,
        AggregatorV3Interface feed,
        uint32 stalenessRegular,
        uint32 stalenessExtended,
        uint32 stalenessClosed,
        uint16 moveCapBps,
        uint16 streamDivergenceBps
    ) internal {
        vm.prank(gov);
        guard.configureFeed(
            collateralToken,
            loanToken,
            feed,
            stalenessRegular,
            stalenessExtended,
            stalenessClosed,
            moveCapBps,
            1 hours,
            streamDivergenceBps,
            address(nvda),
            address(nvda),
            address(nvda),
            address(0)
        );
    }

    /// @dev Reconfigures NVDA to use the mock stream adapter and otherwise keeps the fixture's settings.
    function _withStream() internal {
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
    }

    // =========================================================================
    // Feed configuration
    // =========================================================================

    function test_quoteTokenIsRecordedAtConfiguration() public view {
        assertEq(guard.quoteToken(address(nvda)), address(usdg));
        assertEq(guard.feedConfig(address(nvda)).loanToken, address(usdg));
    }

    function test_quoteTokenRevertsForAnUnconfiguredToken() public {
        address other = makeAddr("unconfigured");
        vm.expectRevert(abi.encodeWithSelector(IOracleGuard.FeedNotConfigured.selector, other));
        guard.quoteToken(other);
    }

    function test_configureFeedStillAcceptsTheFixtureSettings() public {
        _configure(address(nvda), address(usdg), nvdaFeed, 1 hours, 2 hours, 4 days, 2500, 200);
        assertEq(guard.quote(address(nvda)).price, 176_40_0000);
    }

    function test_configureFeedRejectsAZeroAddress() public {
        vm.expectRevert(OracleGuard.InvalidFeedConfig.selector);
        _configure(address(nvda), address(usdg), AggregatorV3Interface(address(0)), 1 hours, 2 hours, 4 days, 2500, 200);

        vm.expectRevert(OracleGuard.InvalidFeedConfig.selector);
        _configure(address(0), address(usdg), nvdaFeed, 1 hours, 2 hours, 4 days, 2500, 200);

        vm.expectRevert(OracleGuard.InvalidFeedConfig.selector);
        _configure(address(nvda), address(0), nvdaFeed, 1 hours, 2 hours, 4 days, 2500, 200);
    }

    /// If the collateral and the loan token were the same, the LTV would just be the token measured against
    /// itself, which means nothing.
    function test_configureFeedRejectsATokenPricedInItself() public {
        vm.expectRevert(OracleGuard.InvalidFeedConfig.selector);
        _configure(address(nvda), address(nvda), nvdaFeed, 1 hours, 2 hours, 4 days, 2500, 200);
    }

    /// With a staleness limit of zero no price is ever fresh enough for that session, so new loans and
    /// liquidations on the token would be blocked outright.
    function test_configureFeedRejectsAZeroStalenessBound() public {
        vm.expectRevert(OracleGuard.InvalidFeedConfig.selector);
        _configure(address(nvda), address(usdg), nvdaFeed, 0, 2 hours, 4 days, 2500, 200);

        vm.expectRevert(OracleGuard.InvalidFeedConfig.selector);
        _configure(address(nvda), address(usdg), nvdaFeed, 1 hours, 0, 4 days, 2500, 200);

        vm.expectRevert(OracleGuard.InvalidFeedConfig.selector);
        _configure(address(nvda), address(usdg), nvdaFeed, 1 hours, 2 hours, 0, 2500, 200);
    }

    function test_configureFeedRejectsBoundsAboveOneHundredPercent() public {
        vm.expectRevert(OracleGuard.InvalidFeedConfig.selector);
        _configure(address(nvda), address(usdg), nvdaFeed, 1 hours, 2 hours, 4 days, 10_001, 200);

        vm.expectRevert(OracleGuard.InvalidFeedConfig.selector);
        _configure(address(nvda), address(usdg), nvdaFeed, 1 hours, 2 hours, 4 days, 2500, 10_001);
    }

    /// A move cap whose window is zero would never have a reference young enough to compare against. It would
    /// look switched on while being unable to trigger.
    function test_configureFeedRejectsAMoveCapWithNoWindow() public {
        vm.prank(gov);
        vm.expectRevert(OracleGuard.InvalidFeedConfig.selector);
        guard.configureFeed(
            address(nvda),
            address(usdg),
            nvdaFeed,
            1 hours,
            2 hours,
            4 days,
            2500,
            0,
            200,
            address(nvda),
            address(nvda),
            address(nvda),
            address(0)
        );
    }

    /// When a feed's decimals exceed the loan token's, a small but positive answer can scale down to zero. That
    /// would price the collateral at nothing and make any caller dividing by the price panic.
    function test_quoteRejectsAPriceThatRescalesToZero() public {
        MockERC20 penny = new MockERC20("Penny Stock Token", "PENNYx", 18);
        MockAggregatorV3 pennyFeed = new MockAggregatorV3(18, 1e5); // 1e-13, far below a single base unit of USDG
        _configure(
            address(penny),
            address(usdg),
            AggregatorV3Interface(address(pennyFeed)),
            1 hours,
            2 hours,
            4 days,
            2500,
            200
        );

        vm.expectRevert(abi.encodeWithSelector(IOracleGuard.PriceInvalid.selector, address(penny)));
        guard.quote(address(penny));

        // The lowest price the guard will quote is one base unit of USDG.
        pennyFeed.set(1e12);
        assertEq(guard.quote(address(penny)).price, 1);
    }

    // =========================================================================
    // Trading schedule and manual pauses
    // =========================================================================

    function test_setScheduleRejectsSessionsThatCloseBeforeTheyOpen() public {
        vm.startPrank(gov);
        vm.expectRevert(OracleGuard.InvalidSchedule.selector);
        guard.setSchedule(OracleGuard.Schedule(21 hours, 14 hours + 30 minutes, 9 hours, 25 hours));
        vm.expectRevert(OracleGuard.InvalidSchedule.selector);
        guard.setSchedule(OracleGuard.Schedule(14 hours + 30 minutes, 21 hours, 25 hours, 9 hours));
        vm.expectRevert(OracleGuard.InvalidSchedule.selector);
        guard.setSchedule(OracleGuard.Schedule(14 hours + 30 minutes, 25 hours, 9 hours, 26 hours));
        vm.expectRevert(OracleGuard.InvalidSchedule.selector);
        guard.setSchedule(OracleGuard.Schedule(14 hours + 30 minutes, 21 hours, 9 hours, 2 days));

        // The stock schedule runs extended hours over midnight, and that shape must keep passing validation.
        guard.setSchedule(OracleGuard.Schedule(14 hours + 30 minutes, 21 hours, 9 hours, 25 hours));
        vm.stopPrank();
    }

    function test_pauseAndResumeRefuseAnUnconfiguredToken() public {
        address other = makeAddr("unconfigured");
        vm.startPrank(gov);
        vm.expectRevert(abi.encodeWithSelector(IOracleGuard.FeedNotConfigured.selector, other));
        guard.pause(other);
        vm.expectRevert(abi.encodeWithSelector(IOracleGuard.FeedNotConfigured.selector, other));
        guard.resume(other);

        guard.pause(address(nvda));
        assertTrue(guard.checkpoint(address(nvda)).paused);
        guard.resume(address(nvda));
        assertFalse(guard.checkpoint(address(nvda)).paused);
        vm.stopPrank();
    }

    function test_pauseAndResumeRefuseToRepeatThemselves() public {
        vm.startPrank(gov);
        vm.expectRevert(abi.encodeWithSelector(OracleGuard.PauseUnchanged.selector, address(nvda)));
        guard.resume(address(nvda));

        guard.pause(address(nvda));
        vm.expectRevert(abi.encodeWithSelector(OracleGuard.PauseUnchanged.selector, address(nvda)));
        guard.pause(address(nvda));
        vm.stopPrank();
    }

    // =========================================================================
    // Sequencer uptime
    // =========================================================================

    /// In the fixture the sequencer came up a week ago, which is long past any grace period.
    function test_sequencerUpForAWhileIsNotGrace() public view {
        assertFalse(guard.quote(address(nvda)).sequencerGrace);
    }

    /// Right after the uptime feed is deployed or migrated, its first round can carry a start time of zero. Taken
    /// at face value that dates the sequencer to 1970, older than any grace window, and the guard would allow
    /// liquidations at exactly the moment it has the least information about the chain.
    function test_sequencerRoundWithNoStartTimeCountsAsGrace() public {
        sequencer.setWithTimestamps(0, 0, block.timestamp);
        assertTrue(guard.quote(address(nvda)).sequencerGrace);
    }

    /// A start time later than the current block is just as uninformative, and the elapsed time would underflow.
    function test_sequencerRoundDatedAheadOfTheBlockCountsAsGrace() public {
        sequencer.setWithTimestamps(0, block.timestamp + 1 days, block.timestamp);
        assertTrue(guard.quote(address(nvda)).sequencerGrace);
    }

    function test_sequencerReportedDownCountsAsGrace() public {
        sequencer.setWithTimestamps(1, block.timestamp - 7 days, block.timestamp);
        assertTrue(guard.quote(address(nvda)).sequencerGrace);
    }

    // =========================================================================
    // Data Streams reports
    // =========================================================================

    function test_freshStreamReportIsAccepted() public {
        _withStream();
        stream.set(176_50_000_000);
        assertEq(guard.verifyStreamReport(address(nvda), hex"01"), 176_50_0000);
    }

    /// Buyers must supply a report so that a sale is priced off something newer than the feed. Signatures do not
    /// expire while the signing key is valid, so without an age check an old report could be replayed days later
    /// and still pass, turning the requirement into paperwork.
    function test_staleStreamReportIsRejected() public {
        _withStream();
        stream.set(176_50_000_000);
        uint256 reportedAt = stream.reportedAt();
        assertEq(reportedAt, block.timestamp, "the mock timestamps a new report with the block time");

        // 59 minutes is within the regular session's one hour limit.
        vm.warp(reportedAt + 59 minutes);
        _setPrice(NVDA_PRICE_8);
        assertEq(guard.verifyStreamReport(address(nvda), hex"01"), 176_50_0000);

        vm.warp(reportedAt + 61 minutes);
        _setPrice(NVDA_PRICE_8);
        vm.expectRevert(abi.encodeWithSelector(OracleGuard.StreamStale.selector, reportedAt));
        guard.verifyStreamReport(address(nvda), hex"01");
    }

    function test_streamReportWithNoTimestampIsRejected() public {
        _withStream();
        stream.setWithTimestamp(176_50_000_000, 0);
        vm.expectRevert(abi.encodeWithSelector(OracleGuard.StreamStale.selector, 0));
        guard.verifyStreamReport(address(nvda), hex"01");
    }

    function test_streamReportDatedAheadOfTheBlockIsRejected() public {
        _withStream();
        uint256 ahead = block.timestamp + 1;
        stream.setWithTimestamp(176_50_000_000, ahead);
        vm.expectRevert(abi.encodeWithSelector(OracleGuard.StreamStale.selector, ahead));
        guard.verifyStreamReport(address(nvda), hex"01");
    }

    /// A report that is properly signed and recent can still fail, because its price is compared with the feed
    /// and anything outside the configured tolerance is turned away.
    function test_divergentStreamReportIsStillRejected() public {
        _withStream();
        stream.set(200_00_000_000);
        vm.expectRevert(
            abi.encodeWithSelector(OracleGuard.StreamDivergence.selector, uint256(176_40_0000), uint256(200_00_0000))
        );
        guard.verifyStreamReport(address(nvda), hex"01");
    }
}
