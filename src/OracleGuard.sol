// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IOracleGuard} from "./interfaces/IOracleGuard.sol";
import {IRiskConfig} from "./interfaces/IRiskConfig.sol";
import {
    AggregatorV3Interface,
    IERC8056,
    IOraclePauseSource,
    IMarketStatusSource,
    IStreamAdapter
} from "./interfaces/IExternal.sol";
import {LoanTypes} from "./libraries/LoanTypes.sol";

/// @title OracleGuard
/// @notice Single source of collateral prices for the protocol. For every collateral token the guard reads a
///         Chainlink Data Feed (and, if one is attached, a Data Streams adapter) and returns a quote that also
///         tells the hub and the liquidation auction how far to trust it: which trading session applies, whether
///         the answer has outlived that session's staleness allowance, whether pricing is halted, the token's
///         ERC-8056 multiplier, and whether the L2 sequencer recently restarted and is still in its grace period.
/// @dev Prices are quoted as loan-token base units per whole collateral token. Chainlink equity feeds have the
///      ERC-8056 multiplier baked in already, so the guard reports the multiplier for information only and never
///      applies it. A stale or halted market does not make `quote` revert; the caller reads the flags and decides.
contract OracleGuard is IOracleGuard {
    using SafeCast for uint256;

    /// @dev Everything `configureFeed` stores for one collateral token. Decimal counts are captured up front so
    ///      that quoting never has to query token metadata.
    struct FeedConfig {
        AggregatorV3Interface feed;
        /// @dev Currency of every price for this collateral. Loans secured by it must be denominated in the same
        ///      token, otherwise debt and collateral value would be measured in different units.
        address loanToken;
        uint8 feedDecimals;
        uint8 loanTokenDecimals;
        uint8 collateralDecimals;
        /// @dev Oldest acceptable answer, in seconds, for the regular, extended and closed sessions respectively.
        uint32 stalenessRegular;
        uint32 stalenessExtended;
        uint32 stalenessClosed;
        /// @dev Biggest change between successive checkpoints that is tolerated before the market is halted. A
        ///      value of zero turns the cap off.
        uint16 moveCapBps;
        /// @dev Age limit on the earlier checkpoint for it to count as a baseline in the move-cap comparison.
        uint32 moveCapWindow;
        /// @dev Widest allowed difference between a verified stream price and the feed price.
        uint16 streamDivergenceBps;
        /// @dev Optional helper contracts; leaving any of them at the zero address disables it.
        address marketStatusSource;
        address pauseSource;
        address multiplierSource;
        address streamAdapter;
        bool configured;
    }

    /// @dev Baseline for the move cap, as last recorded by `refresh`, together with the guard's own halt flag.
    struct Checkpoint {
        uint128 lastPrice;
        uint40 lastAt;
        bool paused;
    }

    /// @notice Weekday session times, in seconds since 00:00 UTC, used for any token without a market-status
    ///         source. `extendedClose` is allowed to exceed one day so that the session can cross midnight.
    struct Schedule {
        uint32 regularOpen;
        uint32 regularClose;
        uint32 extendedOpen;
        uint32 extendedClose;
    }

    /// @dev Session codes from a market-status source that get special treatment. Every other code is read as
    ///      regular trading hours.
    uint8 internal constant STATUS_CLOSED = 5;
    uint8 internal constant STATUS_EXTENDED = 2;

    // =====================================================================
    //                               Storage
    // =====================================================================

    IRiskConfig public immutable riskConfig;
    /// @notice Chainlink uptime feed for the L2 sequencer. While it is unset the sequencer is not checked.
    AggregatorV3Interface public sequencerFeed;
    Schedule public schedule;

    mapping(address => FeedConfig) internal _feeds;
    mapping(address => Checkpoint) internal _checkpoints;

    // =====================================================================
    //                           Events and errors
    // =====================================================================

    event FeedConfigured(address indexed collateralToken, address feed, uint8 feedDecimals, uint8 loanTokenDecimals);
    event SequencerFeedSet(address feed);
    event ScheduleSet(uint32 regularOpen, uint32 regularClose, uint32 extendedOpen, uint32 extendedClose);
    /// @dev For a move-cap trip `newPrice` is the print that broke the cap; for a manual pause it is zero.
    event MarketPausedEvent(address indexed collateralToken, uint256 lastPrice, uint256 newPrice);
    event MarketResumed(address indexed collateralToken);
    event Checkpointed(address indexed collateralToken, uint256 price);

    error NotGovernance();
    /// @dev Rejected by `configureFeed` because the settings could never yield a usable quote.
    error InvalidFeedConfig();
    error InvalidSchedule();
    /// @dev Raised by `pause` when the guard has already halted the market, and by `resume` when it has not.
    error PauseUnchanged(address token);
    error StreamNotConfigured(address token);
    /// @dev The report is too old for the current session, or its timestamp is missing or in the future.
    error StreamStale(uint256 reportedAt);
    error StreamDivergence(uint256 feedPrice, uint256 streamPrice);

    /// @dev Restricts a call to the current owner of the risk config, which acts as governance for the guard.
    modifier onlyGovernance() {
        if (msg.sender != riskConfig.owner()) revert NotGovernance();
        _;
    }

    constructor(IRiskConfig riskConfig_) {
        riskConfig = riskConfig_;
        // Starting schedule matches US equity hours under standard time, written in UTC. Regular trading runs
        // from 14:30 to 21:00. Extended trading opens at 09:00 and closes at 01:00 on the following day, hence a
        // close value of 25 hours.
        schedule = Schedule({
            regularOpen: 14 hours + 30 minutes, regularClose: 21 hours, extendedOpen: 9 hours, extendedClose: 25 hours
        });
    }

    // =====================================================================
    //                         Governance settings
    // =====================================================================

    /// @notice Add a collateral token to the guard, or overwrite its existing pricing setup.
    /// @dev Decimal counts for the feed, the loan token and the collateral are fetched here and nowhere else.
    ///      Overwriting a configuration keeps the token's checkpoint and halt flag untouched.
    ///
    ///      Validation targets settings that would let the token be quoted while making it useless in practice.
    ///      A zero staleness allowance would flag every answer in that session as stale and quietly block both
    ///      new loans and liquidations. Pricing a token against itself, or a basis-point value over 10000, can
    ///      only come from arguments passed in the wrong order. A non-zero move cap paired with a zero window is
    ///      also refused, since no checkpoint could ever be young enough and the cap would be inert while
    ///      appearing active.
    /// @param collateralToken Collateral token to configure.
    /// @param loanToken Token that prices are expressed in. The hub only accepts loans against this collateral
    ///        when they are denominated in it.
    /// @param feed Chainlink aggregator that prices the collateral.
    /// @param stalenessRegular Allowed answer age in seconds while regular trading is open.
    /// @param stalenessExtended Allowed answer age in seconds during extended trading.
    /// @param stalenessClosed Allowed answer age in seconds while the market is shut.
    /// @param moveCapBps Biggest move between checkpoints that will not halt the market, or zero for no cap.
    /// @param moveCapWindow Oldest a baseline checkpoint can be for the move cap to be applied.
    /// @param streamDivergenceBps Allowed gap between a verified stream price and the feed price.
    /// @param marketStatusSource Optional contract reporting the session. When zero the clock schedule is used.
    /// @param pauseSource Optional contract answering `oraclePaused()`, usually the token.
    /// @param multiplierSource Optional ERC-8056 contract, usually the token.
    /// @param streamAdapter Optional Data Streams verifier. When zero the token has no stream.
    function configureFeed(
        address collateralToken,
        address loanToken,
        AggregatorV3Interface feed,
        uint32 stalenessRegular,
        uint32 stalenessExtended,
        uint32 stalenessClosed,
        uint16 moveCapBps,
        uint32 moveCapWindow,
        uint16 streamDivergenceBps,
        address marketStatusSource,
        address pauseSource,
        address multiplierSource,
        address streamAdapter
    ) external onlyGovernance {
        require(
            address(feed) != address(0) && collateralToken != address(0) && loanToken != address(0),
            InvalidFeedConfig()
        );
        require(collateralToken != loanToken, InvalidFeedConfig());
        require(stalenessRegular != 0 && stalenessExtended != 0 && stalenessClosed != 0, InvalidFeedConfig());
        require(moveCapBps <= LoanTypes.BPS && streamDivergenceBps <= LoanTypes.BPS, InvalidFeedConfig());
        require(moveCapBps == 0 || moveCapWindow != 0, InvalidFeedConfig());

        uint8 aggDecimals = feed.decimals();
        uint8 loanDecimals = IERC20Metadata(loanToken).decimals();
        uint8 collDecimals = IERC20Metadata(collateralToken).decimals();
        _feeds[collateralToken] = FeedConfig({
            feed: feed,
            loanToken: loanToken,
            feedDecimals: aggDecimals,
            loanTokenDecimals: loanDecimals,
            collateralDecimals: collDecimals,
            stalenessRegular: stalenessRegular,
            stalenessExtended: stalenessExtended,
            stalenessClosed: stalenessClosed,
            moveCapBps: moveCapBps,
            moveCapWindow: moveCapWindow,
            streamDivergenceBps: streamDivergenceBps,
            marketStatusSource: marketStatusSource,
            pauseSource: pauseSource,
            multiplierSource: multiplierSource,
            streamAdapter: streamAdapter,
            configured: true
        });
        emit FeedConfigured(collateralToken, address(feed), aggDecimals, loanDecimals);
    }

    /// @notice Point the guard at an L2 sequencer uptime feed, or pass the zero address to stop checking it.
    function setSequencerFeed(AggregatorV3Interface feed) external onlyGovernance {
        sequencerFeed = feed;
        emit SequencerFeedSet(address(feed));
    }

    /// @notice Swap in a new clock schedule for tokens that lack a market-status source.
    /// @dev Both sessions must open strictly before they close. Regular hours have to finish no later than
    ///      midnight. Extended hours may cross midnight but must finish before the second midnight, because
    ///      `_clockSession` only looks one day back when handling the overflow.
    function setSchedule(Schedule calldata s) external onlyGovernance {
        if (s.regularOpen >= s.regularClose || s.regularClose > 1 days) revert InvalidSchedule();
        if (s.extendedOpen >= s.extendedClose || s.extendedOpen >= 1 days || s.extendedClose >= 2 days) {
            revert InvalidSchedule();
        }
        schedule = s;
        emit ScheduleSet(s.regularOpen, s.regularClose, s.extendedOpen, s.extendedClose);
    }

    // =====================================================================
    //                           Manual halts
    // =====================================================================

    /// @notice Halt pricing for a market by hand. The emitted event pairs the latest checkpoint with a new price
    ///         of zero, which distinguishes it from an automatic move-cap halt.
    /// @dev An unconfigured token reverts, so a typo in the address cannot silently halt nothing. Halting a
    ///      market that is already halted reverts with `PauseUnchanged`, which keeps every event meaningful.
    function pause(address collateralToken) external onlyGovernance {
        _configured(collateralToken);
        Checkpoint storage mark = _checkpoints[collateralToken];
        if (mark.paused) revert PauseUnchanged(collateralToken);
        mark.paused = true;
        emit MarketPausedEvent(collateralToken, mark.lastPrice, 0);
    }

    /// @notice Lift the guard's halt on a market, regardless of whether governance or the move cap raised it.
    ///         A halt reported by the token's own pause source is outside the guard's control and stays.
    /// @dev The checkpoint is kept. While the old baseline is still within the move-cap window, the next
    ///      `refresh` measures against it and can halt the market again. Lifting a halt that is not in place
    ///      reverts with `PauseUnchanged`.
    function resume(address collateralToken) external onlyGovernance {
        _configured(collateralToken);
        Checkpoint storage mark = _checkpoints[collateralToken];
        if (!mark.paused) revert PauseUnchanged(collateralToken);
        mark.paused = false;
        emit MarketResumed(collateralToken);
    }

    // =====================================================================
    //                              Pricing
    // =====================================================================

    /// @inheritdoc IOracleGuard
    /// @dev The only reverts are for an unconfigured token and for a feed answer that is zero or negative,
    ///      carries a zero timestamp, or is dated after the current block. Every other concern is reported in the
    ///      quote's flags. `paused` is set if either the guard has halted the market or the token's pause source
    ///      says so.
    ///
    ///      Converting to loan-token decimals can round a small positive answer down to zero when the feed has
    ///      more decimals than the loan token. A zero price would value collateral at nothing and callers divide
    ///      by it, so the guard rejects it here.
    function quote(address collateralToken) public view override returns (Quote memory q) {
        FeedConfig storage cfg = _configured(collateralToken);

        (, int256 answer,, uint256 updatedAt,) = cfg.feed.latestRoundData();
        if (answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp) revert PriceInvalid(collateralToken);

        q.price = _scaleDecimals(uint256(answer), cfg.feedDecimals, cfg.loanTokenDecimals);
        if (q.price == 0) revert PriceInvalid(collateralToken);
        q.updatedAt = uint64(updatedAt);
        q.session = _currentSession(cfg);
        q.stale = block.timestamp - updatedAt > _stalenessFor(cfg, q.session);
        q.paused = _checkpoints[collateralToken].paused || _sourcePaused(cfg);
        q.multiplier = _multiplierOf(cfg);
        q.sequencerGrace = _sequencerInGrace();
    }

    /// @inheritdoc IOracleGuard
    /// @dev If the move cap trips, the checkpoint stays where it was and the quote is returned with `paused`
    ///      set. An already halted market goes through the same path, so its checkpoint keeps advancing for as
    ///      long as each new price stays within the cap.
    function refresh(address collateralToken) external override returns (Quote memory q) {
        q = quote(collateralToken);
        FeedConfig storage cfg = _feeds[collateralToken];
        Checkpoint storage mark = _checkpoints[collateralToken];

        // The cap exists to catch one rogue print, which only makes sense against a fresh baseline. Checkpoints
        // are written solely here, so a thinly used market may be comparing against a price from days ago, and
        // normal drift over that time would look like a jump. When the window has passed, the new price simply
        // becomes the baseline.
        bool withinWindow =
            mark.lastPrice != 0 && cfg.moveCapBps != 0 && block.timestamp - mark.lastAt <= cfg.moveCapWindow;
        if (withinWindow) {
            uint256 baseline = mark.lastPrice;
            if (_deviationBps(q.price, baseline) > cfg.moveCapBps) {
                mark.paused = true;
                q.paused = true;
                emit MarketPausedEvent(collateralToken, baseline, q.price);
                return q;
            }
        }

        mark.lastPrice = q.price.toUint128();
        mark.lastAt = uint40(block.timestamp);
        emit Checkpointed(collateralToken, q.price);
    }

    /// @inheritdoc IOracleGuard
    /// @dev Signature checking is left to the adapter. The guard converts the adapter's price to loan-token
    ///      units, makes sure the report is fresh, and refuses it if it is further from the feed price than
    ///      `streamDivergenceBps` permits.
    ///
    ///      Buyers are asked for a report so that a sale is based on a newer price than the feed can offer. A
    ///      signed report remains verifiable for the lifetime of the signing key, so without an age limit an old
    ///      report could be replayed long after the fact and still pass, which would make the requirement
    ///      meaningless. The limit used is the current session's staleness allowance, the same one applied to
    ///      the feed. Streams update far more frequently than that, so any honest report clears it easily.
    function verifyStreamReport(address collateralToken, bytes calldata report)
        external
        override
        returns (uint256 price)
    {
        FeedConfig storage cfg = _configured(collateralToken);
        if (cfg.streamAdapter == address(0)) revert StreamNotConfigured(collateralToken);

        (uint256 raw, uint256 reportedAt) = IStreamAdapter(cfg.streamAdapter).verify(collateralToken, report);
        price = _scaleDecimals(raw, cfg.feedDecimals, cfg.loanTokenDecimals);
        if (price == 0) revert PriceInvalid(collateralToken);

        Quote memory feedQuote = quote(collateralToken);
        bool tooOld = reportedAt == 0 || reportedAt > block.timestamp
            || block.timestamp - reportedAt > _stalenessFor(cfg, feedQuote.session);
        if (tooOld) revert StreamStale(reportedAt);

        if (_deviationBps(price, feedQuote.price) > cfg.streamDivergenceBps) {
            revert StreamDivergence(feedQuote.price, price);
        }
    }

    // =====================================================================
    //                               Views
    // =====================================================================

    /// @inheritdoc IOracleGuard
    function quoteToken(address collateralToken) external view override returns (address) {
        return _configured(collateralToken).loanToken;
    }

    /// @inheritdoc IOracleGuard
    function collateralDecimals(address collateralToken) external view override returns (uint8) {
        return _configured(collateralToken).collateralDecimals;
    }

    /// @inheritdoc IOracleGuard
    function hasStream(address collateralToken) external view override returns (bool) {
        return _feeds[collateralToken].streamAdapter != address(0);
    }

    /// @notice True if pricing for the market is halted, either by the guard (by hand or by the move cap) or by
    ///         the token's own pause source. Unlike `quote`, this never reverts on a bad feed answer, so a status
    ///         page can show the halt even while the feed itself is broken.
    /// @dev Reverts only for an unconfigured token.
    function isMarketPaused(address collateralToken) external view returns (bool) {
        FeedConfig storage cfg = _configured(collateralToken);
        return _checkpoints[collateralToken].paused || _sourcePaused(cfg);
    }

    /// @notice Complete stored setup for a token. A token that was never configured comes back as all zeroes.
    function feedConfig(address collateralToken) external view returns (FeedConfig memory) {
        return _feeds[collateralToken];
    }

    /// @notice A token's move-cap baseline and the guard's halt flag for it.
    function checkpoint(address collateralToken) external view returns (Checkpoint memory) {
        return _checkpoints[collateralToken];
    }

    // =====================================================================
    //                          Internal helpers
    // =====================================================================

    /// @dev Storage pointer to a token's setup, reverting with `FeedNotConfigured` if it has none.
    function _configured(address collateralToken) internal view returns (FeedConfig storage cfg) {
        cfg = _feeds[collateralToken];
        if (!cfg.configured) revert FeedNotConfigured(collateralToken);
    }

    /// @dev Session in force for a token. A market-status source takes precedence; without one the clock decides.
    function _currentSession(FeedConfig storage cfg) internal view returns (LoanTypes.Session) {
        if (cfg.marketStatusSource == address(0)) return _clockSession();
        uint8 code = IMarketStatusSource(cfg.marketStatusSource).marketStatus();
        if (code == STATUS_CLOSED) return LoanTypes.Session.Closed;
        if (code == STATUS_EXTENDED) return LoanTypes.Session.Extended;
        return LoanTypes.Session.Regular;
    }

    /// @dev Session derived from the block time alone. Weekends are closed and weekdays follow `schedule`. It
    ///      knows nothing of exchange holidays, which is why production tokens ought to have a market-status
    ///      source.
    function _clockSession() internal view returns (LoanTypes.Session) {
        // 1 January 1970 fell on a Thursday; adding four makes 0 Sunday and 6 Saturday.
        uint256 dayOfWeek = (block.timestamp / 1 days + 4) % 7;
        uint256 secondsIntoDay = block.timestamp % 1 days;
        Schedule memory s = schedule;

        // When extended hours run beyond midnight, the small hours belong to the previous day's session, and
        // whether that session existed depends on whether the previous day was a weekday.
        if (s.extendedClose > 1 days && secondsIntoDay < s.extendedClose - 1 days) {
            uint256 previousDay = (dayOfWeek + 6) % 7;
            return (previousDay == 0 || previousDay == 6) ? LoanTypes.Session.Closed : LoanTypes.Session.Extended;
        }
        if (dayOfWeek == 0 || dayOfWeek == 6) return LoanTypes.Session.Closed;
        if (secondsIntoDay >= s.regularOpen && secondsIntoDay < s.regularClose) return LoanTypes.Session.Regular;
        uint256 extendedEndToday = s.extendedClose > 1 days ? 1 days : s.extendedClose;
        if (secondsIntoDay >= s.extendedOpen && secondsIntoDay < extendedEndToday) {
            return LoanTypes.Session.Extended;
        }
        return LoanTypes.Session.Closed;
    }

    /// @dev Allowed answer age for the given session.
    function _stalenessFor(FeedConfig storage cfg, LoanTypes.Session session) internal view returns (uint256) {
        if (session == LoanTypes.Session.Regular) return cfg.stalenessRegular;
        if (session == LoanTypes.Session.Extended) return cfg.stalenessExtended;
        return cfg.stalenessClosed;
    }

    /// @dev Asks the token's pause source. No source, or a source that reverts, is read as not halted.
    function _sourcePaused(FeedConfig storage cfg) internal view returns (bool) {
        if (cfg.pauseSource == address(0)) return false;
        try IOraclePauseSource(cfg.pauseSource).oraclePaused() returns (bool halted) {
            return halted;
        } catch {
            return false;
        }
    }

    /// @dev ERC-8056 multiplier for the token, defaulting to 1e18 if there is no source, the call reverts, or
    ///      the source answers zero.
    function _multiplierOf(FeedConfig storage cfg) internal view returns (uint256) {
        if (cfg.multiplierSource == address(0)) return LoanTypes.WAD;
        try IERC8056(cfg.multiplierSource).uiMultiplier() returns (uint256 value) {
            return value == 0 ? LoanTypes.WAD : value;
        } catch {
            return LoanTypes.WAD;
        }
    }

    /// @dev Reads the Chainlink sequencer uptime feed, if one is configured. An answer of 0 means up and 1
    ///      means down, and `startedAt` is when the present status took effect. After a restart the grace
    ///      period runs for `sequencerGrace` seconds, as set in the risk config.
    ///
    ///      A round whose `startedAt` is zero or later than the current block carries no information. The uptime
    ///      feed publishes a zero `startedAt` while its first round after deployment or migration is still
    ///      settling, and taken at face value that would date the restart to 1970, well outside any grace
    ///      period. That would let loans and liquidations through at exactly the moment the guard can say least
    ///      about the chain, so such a round is treated as being in grace.
    function _sequencerInGrace() internal view returns (bool) {
        if (address(sequencerFeed) == address(0)) return false;
        (, int256 answer, uint256 startedAt,,) = sequencerFeed.latestRoundData();
        // A sequencer that is down is reported as in grace, which also stops auctions from opening.
        if (answer != 0) return true;
        if (startedAt == 0 || startedAt > block.timestamp) return true;
        uint256 gracePeriod = riskConfig.loanParams().sequencerGrace;
        return block.timestamp - startedAt < gracePeriod;
    }

    /// @dev Converts an amount between two decimal scales, rounding down when the target scale is smaller.
    function _scaleDecimals(uint256 amount, uint8 fromDecimals, uint8 toDecimals) internal pure returns (uint256) {
        if (toDecimals >= fromDecimals) return amount * (10 ** (toDecimals - fromDecimals));
        return amount / (10 ** (fromDecimals - toDecimals));
    }

    /// @dev Absolute difference between `value` and `reference_`, in basis points of `reference_`.
    function _deviationBps(uint256 value, uint256 reference_) internal pure returns (uint256) {
        uint256 diff = value > reference_ ? value - reference_ : reference_ - value;
        return diff * LoanTypes.BPS / reference_;
    }
}
