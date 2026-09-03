// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ICreditHub} from "./interfaces/ICreditHub.sol";
import {IRiskConfig} from "./interfaces/IRiskConfig.sol";
import {IPermissionRegistry} from "./interfaces/IPermissionRegistry.sol";
import {IOracleGuard} from "./interfaces/IOracleGuard.sol";
import {LoanTypes, Permissions} from "./libraries/LoanTypes.sol";

/// @title LiquidationAuction
/// @notice Descending-price sale of a loan's escrowed collateral. Each auction opens at the guard's price plus a
///         premium and slides linearly down to a floor across a set window. It stops as soon as buyers have paid
///         enough to cover the debt and the penalty, or when no collateral is left. Before anyone can buy, two
///         groups are dealt with: lenders who chose in-kind settlement are paid in collateral at the quoted
///         price, and, when the market is shut, the slices whose lenders refused closed-market liquidation are
///         moved into a separate loan that continues as normal.
/// @dev Payments from buyers land directly on the hub, which runs the penalty waterfall when
///      `finalizeLiquidation` is called. This contract never holds funds of its own; its only job is to drive
///      the hub's liquidation states from one step to the next.
contract LiquidationAuction is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @dev State of the auction for a single loan id. Both prices are quoted in loan-token base units per whole
    ///      collateral token, while `target` and `proceeds` are plain loan-token base units. `keeper` is the
    ///      address that opened the auction and is owed the keeper cut of the penalty.
    struct Auction {
        uint40 startedAt;
        uint32 duration;
        uint128 startPrice;
        uint128 floorPrice;
        uint128 target;
        uint128 proceeds;
        address keeper;
        LoanTypes.Session session;
        bool active;
    }

    ICreditHub public immutable hub;
    IRiskConfig public immutable riskConfig;
    IPermissionRegistry public immutable permissions;
    IOracleGuard public immutable oracleGuard;

    /// @notice Per-loan auction records. `active` reads false until an auction opens and again once it settles.
    mapping(uint256 => Auction) public auctions;

    /// @notice Emitted when an auction begins. `target` captures the debt plus penalty owed at that instant.
    event AuctionStarted(
        uint256 indexed loanId,
        address indexed keeper,
        uint256 startPrice,
        uint256 floorPrice,
        uint256 target,
        LoanTypes.Session session
    );
    /// @notice Emitted on each purchase: `buyer` received `collateralAmount` and paid `cost` at unit price `price`.
    event AuctionBuy(
        uint256 indexed loanId, address indexed buyer, uint256 collateralAmount, uint256 cost, uint256 price
    );
    /// @notice Emitted when an expired auction is given a new schedule built from a fresh price.
    event AuctionRestarted(
        uint256 indexed loanId,
        address indexed caller,
        uint256 startPrice,
        uint256 floorPrice,
        uint256 target,
        LoanTypes.Session session
    );
    /// @notice Emitted when the sale is over and the hub has finalised the liquidation with `proceeds`.
    event AuctionSettled(uint256 indexed loanId, uint256 proceeds);

    /// @dev Liquidations are currently paused by the guardian.
    error LiquidationsPaused();
    /// @dev The loan is healthy (factor of at least 1.0), not defaulted, and still within its grace window.
    error NotLiquidatable();
    /// @dev The sequencer restarted too recently and is still inside its grace period.
    error SequencerGrace();
    /// @dev Trading in the collateral token is paused according to the guard.
    error GuardPaused();
    /// @dev The price feed has gone stale in a session where it should be updating.
    error OracleStale();
    /// @dev There is no running auction for this loan.
    error AuctionNotActive();
    /// @dev This loan already has a running auction.
    error AuctionAlreadyActive();
    /// @dev A restart is only allowed once the current window has elapsed.
    error AuctionNotEnded();
    /// @dev The market is shut and all of the loan's slices declined closed-market liquidation.
    error NoClosedMarketLiquidation();
    /// @dev A Data Streams adapter is configured for the token but no report was supplied with the buy.
    error StreamReportRequired();
    /// @dev After rounding, the purchase would move no collateral or cost nothing.
    error NothingToBuy();
    /// @dev When the purchase executed, the auction price exceeded the limit set by the buyer.
    error PriceAboveLimit(uint256 price, uint256 maxPrice);

    /// @dev Rejects the call while the guardian has liquidations paused.
    modifier whenLiquidationsLive() {
        if (riskConfig.liquidationsPaused()) revert LiquidationsPaused();
        _;
    }

    constructor(ICreditHub hub_, IRiskConfig riskConfig_, IPermissionRegistry permissions_, IOracleGuard oracleGuard_) {
        hub = hub_;
        riskConfig = riskConfig_;
        permissions = permissions_;
        oracleGuard = oracleGuard_;
    }

    /*//////////////////////////////////////////////////////////////
                        AUCTION LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    /// @notice Starts an auction on a loan that can be liquidated. Anyone may call, and the caller is recorded as
    ///         the keeper.
    /// @dev Three conditions make a loan eligible: a health factor under 1.0, a `Defaulted` status, or an
    ///      `Active` status with maturity and the grace window both behind it. The steps run in this order:
    ///      checkpoint a price with the guard, switch the loan to `Liquidating` (the hub cancels any rollover in
    ///      progress), carve off opted-out slices when the market is shut, pay the in-kind lenders, and finally
    ///      either settle straight away if no collateral remains or store the price schedule.
    /// @param loanId Identifier of the loan to liquidate.
    function startAuction(uint256 loanId) external nonReentrant whenLiquidationsLive {
        if (auctions[loanId].active) revert AuctionAlreadyActive();

        LoanTypes.Loan memory loan = hub.getLoan(loanId);
        // We call `refresh` rather than `quote` because this is the only price read on the way into a forced
        // sale, and the move cap must be recorded at this point. A read-only quote would leave the circuit
        // breaker trusting whatever origination stored last, which defeats its purpose of shielding borrowers
        // from a single bad print.
        IOracleGuard.Quote memory quote = oracleGuard.refresh(loan.collateralToken);
        _assertQuoteUsable(quote);

        bool overdue = loan.status == LoanTypes.LoanStatus.Defaulted || _isOverdue(loan);
        if (!overdue && hub.healthFactor(loanId) >= LoanTypes.WAD) revert NotLiquidatable();

        hub.beginLiquidation(loanId);

        // With the market shut, lenders who declined closed-market liquidation keep their slices in a new
        // Active loan that is left out of the sale. When that covers every slice, the auction has nothing to sell.
        if (quote.session == LoanTypes.Session.Closed) {
            uint256[] memory excluded = _filterSlicesByFlag(loan.sliceIds, LoanTypes.FLAG_NO_CLOSED_MARKET_LIQUIDATION);
            if (excluded.length == loan.sliceIds.length) revert NoClosedMarketLiquidation();
            if (excluded.length > 0) hub.splitForLiquidation(loanId, excluded);
        }

        // Lenders who asked to be paid in collateral are served out of escrow at the recorded price first.
        loan = hub.getLoan(loanId);
        uint256[] memory inKindSlices = _filterSlicesByFlag(loan.sliceIds, LoanTypes.FLAG_SELF_LIQUIDATE);
        for (uint256 idx; idx < inKindSlices.length; ++idx) {
            hub.settleInKind(loanId, inKindSlices[idx], quote.price);
        }

        // If the in-kind payouts used everything up, settle the liquidation with no proceeds.
        loan = hub.getLoan(loanId);
        if (loan.sliceIds.length == 0 || loan.collateralAmount == 0) {
            hub.finalizeLiquidation(loanId, 0, msg.sender);
            emit AuctionSettled(loanId, 0);
            return;
        }

        (uint256 startPrice, uint256 floorPrice, uint256 targetAmount, uint32 window) = _buildSchedule(loanId, quote);
        auctions[loanId] = Auction({
            startedAt: uint40(block.timestamp),
            duration: window,
            startPrice: startPrice.toUint128(),
            floorPrice: floorPrice.toUint128(),
            target: targetAmount.toUint128(),
            proceeds: 0,
            keeper: msg.sender,
            session: quote.session,
            active: true
        });
        emit AuctionStarted(loanId, msg.sender, startPrice, floorPrice, targetAmount, quote.session);
    }

    /// @notice Gives an expired auction a new price schedule when its window ran out before the target was met.
    ///         Open to any caller.
    /// @dev Without this, an auction started in a falling market could sit at an outdated floor forever while
    ///      the loan stays in `Liquidating`, unable to be repaid and with its collateral frozen. Restarting leaves
    ///      the loan in liquidation and derives a new start, floor, target and window from a fresh price.
    ///      Whatever has been collected so far is kept and counts against the new target, and the keeper share
    ///      still belongs to whoever opened the auction.
    /// @param loanId Identifier of the loan whose auction window has run out.
    function restart(uint256 loanId) external nonReentrant whenLiquidationsLive {
        Auction storage auction = _activeAuction(loanId);
        if (block.timestamp < uint256(auction.startedAt) + auction.duration) revert AuctionNotEnded();

        LoanTypes.Loan memory loan = hub.getLoan(loanId);
        IOracleGuard.Quote memory quote = oracleGuard.refresh(loan.collateralToken);
        _assertQuoteUsable(quote);

        (uint256 startPrice, uint256 floorPrice, uint256 targetAmount, uint32 window) = _buildSchedule(loanId, quote);
        auction.startedAt = uint40(block.timestamp);
        auction.duration = window;
        auction.startPrice = startPrice.toUint128();
        auction.floorPrice = floorPrice.toUint128();
        auction.target = targetAmount.toUint128();
        auction.session = quote.session;
        emit AuctionRestarted(loanId, msg.sender, startPrice, floorPrice, targetAmount, quote.session);
    }

    /// @notice Purchases collateral, up to `collateralAmount`, at the price the schedule gives right now. The
    ///         caller must hold the LIQUIDATOR role.
    /// @dev The quantity is trimmed in two ways: it cannot exceed what remains in escrow, and it cannot cost more
    ///      than the amount still missing from the target, so the sale never raises more than it needs. The
    ///      buyer pays the hub directly and receives collateral released from escrow. Tokens with a Data Streams
    ///      adapter need a signed report, which the guard checks before anything moves, although the price paid
    ///      is always the scheduled one. Reaching the target or emptying the escrow closes the auction and has
    ///      the hub finalise. Nothing stops the sale when the window ends: the floor simply holds until somebody
    ///      buys or calls `restart`.
    ///
    ///      Pausing liquidations stops purchases too, not only new auctions. The guardian pauses when the
    ///      protocol's inputs can no longer be trusted, and a running auction keeps stepping down along a schedule
    ///      derived from a price taken before the problem came to light. Allowing buys during a pause would hand
    ///      out collateral at exactly the prices the pause is meant to reject. While paused the loan is stuck in
    ///      liquidation and cannot be repaid, but after the pause is lifted `restart` derives a new schedule from
    ///      a fresh price, so nobody ends up trading on the decline that happened meanwhile.
    /// @param loanId Identifier of the loan being auctioned.
    /// @param collateralAmount Upper bound on the collateral to receive, in collateral base units.
    /// @param streamReport Signed Data Streams report, which can be left empty for tokens without a stream.
    function buy(uint256 loanId, uint256 collateralAmount, bytes calldata streamReport)
        external
        nonReentrant
        whenLiquidationsLive
    {
        _executeBuy(loanId, collateralAmount, type(uint256).max, streamReport);
    }

    /// @notice Same as `buy`, but with a maximum acceptable price per whole collateral token. If the auction price
    ///         is higher than `maxPrice` when the transaction executes, it reverts with `PriceAboveLimit`.
    /// @dev Within one schedule the price can only go down, yet a `restart` builds a new schedule from a new
    ///      quote and may push it higher. This variant protects a buyer whose bid was based on the earlier
    ///      schedule from being filled on the later one.
    function buyWithLimit(uint256 loanId, uint256 collateralAmount, uint256 maxPrice, bytes calldata streamReport)
        external
        nonReentrant
        whenLiquidationsLive
    {
        _executeBuy(loanId, collateralAmount, maxPrice, streamReport);
    }

    /*//////////////////////////////////////////////////////////////
                              VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice The price a purchase would pay at this moment, in loan-token base units per whole collateral
    ///         token. It moves in a straight line from `startPrice` down to `floorPrice` during the window, then
    ///         stays at the floor.
    /// @dev Reverts if `loanId` has no running auction.
    function currentPrice(uint256 loanId) public view returns (uint256) {
        Auction storage auction = _activeAuction(loanId);
        uint256 elapsed = block.timestamp - auction.startedAt;
        if (elapsed >= auction.duration) return auction.floorPrice;
        return auction.startPrice
            - (uint256(auction.startPrice) - auction.floorPrice) * elapsed / auction.duration;
    }

    /// @notice Reports whether `loanId` has a running auction, without having to decode the full `auctions`
    ///         tuple for a single field.
    function isActive(uint256 loanId) external view returns (bool) {
        return auctions[loanId].active;
    }

    /// @notice The timestamp at which the price bottoms out. From then on the floor applies and `restart` is
    ///         available to anyone.
    /// @dev Reverts if `loanId` has no running auction.
    function endsAt(uint256 loanId) external view returns (uint256) {
        Auction storage auction = _activeAuction(loanId);
        return uint256(auction.startedAt) + auction.duration;
    }

    /// @notice Simulates `buy(loanId, collateralAmount, ...)` in the current block, returning the collateral
    ///         that would change hands, its total cost and the unit price. Useful for sizing a bid and approving
    ///         the right allowance up front.
    /// @dev Trims the amount exactly as `buy` does. Reverts if no auction is running, and returns zeros rather
    ///      than reverting when the purchase would be too small to execute.
    function previewBuy(uint256 loanId, uint256 collateralAmount)
        external
        view
        returns (uint256 amount, uint256 cost, uint256 price)
    {
        (amount, cost, price) = _quoteBid(loanId, hub.getLoan(loanId), collateralAmount);
        if (amount == 0 || cost == 0) (amount, cost) = (0, 0);
    }

    /// @notice Returns true for an `Active` loan whose maturity plus grace window has already passed. Such a loan
    ///         can be put up for auction regardless of its health factor.
    /// @param loanId Identifier of the loan to inspect.
    function isPastGrace(uint256 loanId) external view returns (bool) {
        return _isOverdue(hub.getLoan(loanId));
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL: PURCHASES
    //////////////////////////////////////////////////////////////*/

    /// @dev Body shared by `buy` and `buyWithLimit`; the pause check has already run in the modifier.
    function _executeBuy(uint256 loanId, uint256 collateralAmount, uint256 maxPrice, bytes calldata streamReport)
        internal
    {
        Auction storage auction = _activeAuction(loanId);
        permissions.requireRole(msg.sender, Permissions.LIQUIDATOR);

        LoanTypes.Loan memory loan = hub.getLoan(loanId);
        if (oracleGuard.hasStream(loan.collateralToken)) {
            if (streamReport.length == 0) revert StreamReportRequired();
            oracleGuard.verifyStreamReport(loan.collateralToken, streamReport);
        }

        (uint256 amount, uint256 cost, uint256 price) = _quoteBid(loanId, loan, collateralAmount);
        if (amount == 0 || cost == 0) revert NothingToBuy();
        if (price > maxPrice) revert PriceAboveLimit(price, maxPrice);

        IERC20(loan.loanToken).safeTransferFrom(msg.sender, address(hub), cost);
        hub.transferCollateral(loanId, msg.sender, amount);
        auction.proceeds += cost.toUint128();
        emit AuctionBuy(loanId, msg.sender, amount, cost, price);

        bool targetMet = auction.proceeds >= auction.target;
        if (targetMet || loan.collateralAmount - amount == 0) {
            auction.active = false;
            hub.finalizeLiquidation(loanId, auction.proceeds, auction.keeper);
            emit AuctionSettled(loanId, auction.proceeds);
        }
    }

    /// @dev Works out what a bid actually gets: the amount is capped by the escrowed collateral, then reduced if
    ///      its cost would overshoot the remaining target. Both the real purchase and the preview go through
    ///      here, which keeps them in agreement.
    function _quoteBid(uint256 loanId, LoanTypes.Loan memory loan, uint256 collateralAmount)
        internal
        view
        returns (uint256 amount, uint256 cost, uint256 price)
    {
        Auction storage auction = auctions[loanId];
        price = currentPrice(loanId);
        uint256 oneToken = 10 ** oracleGuard.collateralDecimals(loan.collateralToken);
        amount = collateralAmount < loan.collateralAmount ? collateralAmount : loan.collateralAmount;
        cost = amount * price / oneToken;
        uint256 remaining = auction.target - auction.proceeds;
        if (cost > remaining) {
            cost = remaining;
            amount = cost * oneToken / price;
        }
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL: PRICING AND CHECKS
    //////////////////////////////////////////////////////////////*/

    /// @dev Derives the auction parameters from a quote. The opening price adds the start premium to the quote,
    ///      the floor applies either the regular or the closed-session floor ratio depending on the session, the
    ///      target is the debt owed now plus the penalty on it, and the window length is read from the risk
    ///      config.
    /// @param loanId Identifier of the loan being auctioned.
    /// @param quote A quote that `_assertQuoteUsable` has already accepted.
    /// @return startPrice Opening price in loan-token base units per whole collateral token.
    /// @return floorPrice Price reached once the window ends, in the same units.
    /// @return targetAmount Total proceeds, in loan-token base units, that end the auction.
    /// @return window Length of the descent in seconds.
    function _buildSchedule(uint256 loanId, IOracleGuard.Quote memory quote)
        internal
        view
        returns (uint256 startPrice, uint256 floorPrice, uint256 targetAmount, uint32 window)
    {
        IRiskConfig.AuctionParams memory params = riskConfig.auctionParams();
        uint256 floorBps = quote.session == LoanTypes.Session.Closed ? params.floorBpsClosed : params.floorBpsRegular;
        startPrice = quote.price * (LoanTypes.BPS + params.startPremiumBps) / LoanTypes.BPS;
        floorPrice = quote.price * floorBps / LoanTypes.BPS;
        (uint256 principal, uint256 interest) = hub.debtOf(loanId);
        uint256 debt = principal + interest;
        targetAmount = debt + debt * params.penaltyBps / LoanTypes.BPS;
        window = params.duration;
    }

    /// @dev Applies the tests origination uses before trusting a quote. A paused token, or a sequencer still in
    ///      its grace period, can never justify a forced sale. Nor can a feed that went quiet while the market
    ///      was trading, because the schedule and the in-kind payouts treat the price as fact and the descent
    ///      starts from it. Staleness during a closed session is normal and is covered by the closed floor and
    ///      the LTV haircut.
    /// @param quote The quote under inspection.
    function _assertQuoteUsable(IOracleGuard.Quote memory quote) internal pure {
        if (quote.paused) revert GuardPaused();
        if (quote.sequencerGrace) revert SequencerGrace();
        if (quote.stale && quote.session != LoanTypes.Session.Closed) revert OracleStale();
    }

    /// @dev Loads the auction for `loanId` and reverts with `AuctionNotActive` if it is not running.
    function _activeAuction(uint256 loanId) internal view returns (Auction storage auction) {
        auction = auctions[loanId];
        if (!auction.active) revert AuctionNotActive();
    }

    /// @dev In-memory version of the `isPastGrace` test, also used by `startAuction`.
    function _isOverdue(LoanTypes.Loan memory loan) internal view returns (bool) {
        return loan.status == LoanTypes.LoanStatus.Active
            && block.timestamp > uint256(loan.maturity) + riskConfig.loanParams().graceWindow;
    }

    /// @dev Picks out the ids in `sliceIds` whose slice carries `flag`. A first pass counts the matches, then a
    ///      correctly sized array is allocated and filled.
    ///
    ///      Every slice is read from the hub exactly once and the result cached in memory, so the second pass
    ///      makes no further calls. That matters because `startAuction` filters twice, a loan may hold as many
    ///      slices as the risk config allows, and an auction that cannot fit in a block can never be opened.
    function _filterSlicesByFlag(uint256[] memory sliceIds, uint8 flag)
        internal
        view
        returns (uint256[] memory matches)
    {
        uint256 total = sliceIds.length;
        bool[] memory hit = new bool[](total);
        uint256 hits;
        for (uint256 idx; idx < total; ++idx) {
            if (hub.getSlice(sliceIds[idx]).flags & flag != 0) {
                hit[idx] = true;
                ++hits;
            }
        }
        matches = new uint256[](hits);
        uint256 cursor;
        for (uint256 idx; idx < total; ++idx) {
            if (hit[idx]) matches[cursor++] = sliceIds[idx];
        }
    }
}
