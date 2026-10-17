// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {CreditHub} from "./CreditHub.sol";
import {IRiskConfig} from "./interfaces/IRiskConfig.sol";
import {IPermissionRegistry} from "./interfaces/IPermissionRegistry.sol";
import {LoanTypes} from "./libraries/LoanTypes.sol";
import {QuoteHash} from "./libraries/QuoteHash.sol";

/// @title RolloverMarket
/// @notice Refinances an Active loan into a new term through a rising-rate auction. The borrower starts it ahead
///         of maturity. The offered rate begins at the loan's blended APR and climbs linearly through the window
///         until it reaches that APR plus the spread cap from the risk config. Lenders join by submitting a
///         signed lend offer whose APR does not exceed the current rate, and their funds are collected on the
///         spot. When the money collected covers the outstanding debt plus the rollover fee, the existing lenders
///         are paid off, the fee is sent to the fee vault, and the new lenders hold the slices of a fresh term. If
///         the window closes before that point, any caller can fail the auction, which refunds the new lenders
///         and moves the loan to Defaulted, where it can still be repaid but is also open to liquidation. Up to
///         clearing, the borrower can withdraw instead: lenders are refunded and the loan is restored unchanged.
/// @dev Rate discovery depends only on elapsed time, so no oracle is consulted for it. Prices still matter in
///      two places: each offer's LTV limit is compared with the loan's current LTV, and the hub requires the
///      refinanced loan to be healthy when it clears. Funds collected from lenders sit in this contract until the
///      rollover either clears or is unwound.
contract RolloverMarket is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @dev A single funded commitment. `rate` records the auction rate at the time of the commitment rather than
    ///      the APR on the offer. `digest` identifies the offer that was charged for the fill, so that a refund can
    ///      restore its capacity.
    struct Acceptance {
        address lender;
        uint128 amount;
        uint16 rate;
        uint8 flags;
        bytes32 digest;
    }

    /// @dev Per-loan auction record. `accepted` is the amount of loan token this contract is holding on the loan's
    ///      behalf right now.
    struct Rollover {
        uint40 startedAt;
        uint32 duration;
        uint16 startRate;
        uint16 capRate;
        uint128 accepted;
        bool active;
    }

    /// @dev Declared with the concrete hub type since this contract calls `reserve` and `remainingCapacity`,
    ///      neither of which is part of the hub interface.
    CreditHub public immutable hub;
    IRiskConfig public immutable riskConfig;
    IPermissionRegistry public immutable permissions;

    /// @notice Rollover records keyed by loan id.
    mapping(uint256 => Rollover) public rollovers;
    /// @dev Funded commitments for each loan, oldest first. Cleared whenever a rollover settles, fails or is
    ///      called off.
    mapping(uint256 => Acceptance[]) internal _acceptances;

    /// @notice Emitted when a borrower starts a rollover. The rate climbs from `startRate` to `capRate`, reaching
    ///         it at `endsAt`.
    event RefinanceOpened(uint256 indexed loanId, uint16 startRate, uint16 capRate, uint40 endsAt);
    /// @notice Emitted when `lender` commits `amount` at `rate`. `accepted` is the new running total against
    ///         `target`.
    event RefinanceAccepted(
        uint256 indexed loanId, address indexed lender, uint256 amount, uint16 rate, uint256 accepted, uint256 target
    );
    /// @notice Emitted on success: `newPrincipal` was collected, `fee` went to the fee vault, and the new
    ///         `sliceIds` were minted.
    event RefinanceClearedEvent(uint256 indexed loanId, uint256 newPrincipal, uint256 fee, uint256[] sliceIds);
    /// @notice Emitted when the window expires with `accepted` under `target`. Lenders were refunded and the loan
    ///         now sits in default.
    event RefinanceFailed(uint256 indexed loanId, uint256 accepted, uint256 target);
    /// @notice Emitted when the borrower withdraws the rollover or the hub calls it off before a liquidation.
    event RefinanceCancelledEvent(uint256 indexed loanId);

    /// @dev This loan has no running rollover.
    error NotActive();
    /// @dev This loan already has a running rollover.
    error AlreadyActive();
    /// @dev The window is over and the only remaining action is `fail`.
    error AuctionEnded();
    /// @dev The window is still open, so `fail` is not available yet.
    error AuctionNotEnded();
    /// @dev The APR on the offer exceeds the current auction rate.
    error RateTooHigh(uint16 offered, uint16 current);
    /// @dev The offer is not compatible with this loan; `_assertOfferMatchesLoan` lists the rules.
    error OfferMismatch(bytes32 offerHash);
    /// @dev The fill is zero, or smaller than the offer's `principalMin` while leaving capacity on the offer.
    error FillTooSmall();
    /// @dev Only the hub may call this.
    error NotHub();
    /// @dev Only the borrower of the loan may call this.
    error NotBorrower();
    /// @dev The loan already has as many commitments as the slice cap allows.
    error TooManyAcceptances();

    constructor(CreditHub hub_, IRiskConfig riskConfig_, IPermissionRegistry permissions_) {
        hub = hub_;
        riskConfig = riskConfig_;
        permissions = permissions_;
    }

    /*//////////////////////////////////////////////////////////////
                         BORROWER ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Starts a rollover on one of the caller's loans. The hub confirms the loan is `Active` and has not
    ///         reached maturity, and then switches it to `Refinancing`.
    /// @dev The starting rate is the slices' APR averaged by principal, and the ceiling adds `capSpreadBps` to it.
    ///      The loan can be repaid at any point during the window.
    /// @param loanId Identifier of the loan to refinance.
    function openRefinance(uint256 loanId) external nonReentrant {
        if (rollovers[loanId].active) revert AlreadyActive();
        hub.beginRefinance(loanId, msg.sender);
        uint16 startRate = blendedAprBps(loanId).toUint16();
        IRiskConfig.RefinanceParams memory params = riskConfig.refinanceParams();
        uint16 capRate = startRate + params.capSpreadBps;
        rollovers[loanId] = Rollover({
            startedAt: uint40(block.timestamp),
            duration: params.duration,
            startRate: startRate,
            capRate: capRate,
            accepted: 0,
            active: true
        });
        emit RefinanceOpened(loanId, startRate, capRate, uint40(block.timestamp + params.duration));
    }

    /// @notice Lets the borrower call off a running rollover. All commitments are refunded and the loan goes back
    ///         to `Active` with its existing terms.
    /// @dev This works even after lenders have committed funds. The hub refuses repayment while a loan is in
    ///      `Refinancing`, so without a way out a borrower who simply wanted to repay would be stuck until the
    ///      window ran out and `fail` pushed the loan into `Defaulted`, a state in which any keeper can liquidate
    ///      it regardless of health. Borrowers must always be able to return to repaying what they owe.
    ///
    ///      Lenders lose nothing compared with a failed rollover: their money comes back in full, the offer
    ///      regains its capacity, and nobody guaranteed them the refinance would happen. A borrower who keeps
    ///      opening and withdrawing only locks lender funds for the length of each attempt, at their own gas cost.
    /// @param loanId Identifier of the loan whose rollover should be withdrawn.
    function cancelRefinance(uint256 loanId) external nonReentrant {
        Rollover storage rollover = _activeRollover(loanId);
        LoanTypes.Loan memory loan = hub.getLoan(loanId);
        if (loan.borrower != msg.sender) revert NotBorrower();
        rollover.active = false;
        _refundAll(loanId, loan.loanToken);
        hub.cancelRefinance(loanId);
        emit RefinanceCancelledEvent(loanId);
    }

    /*//////////////////////////////////////////////////////////////
                      LENDER AND KEEPER ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Commits funds to the rollover, in whole or in part, using a signed lend offer. Its APR may not
    ///         exceed the current rate, and the slice it becomes is booked at the current rate instead of the
    ///         offer's APR, so each lender earns whatever rate applied when they joined. If this commitment brings
    ///         the total up to the target, the rollover clears within the same transaction.
    /// @dev The fill is whichever is smaller: the capacity left on the offer or the amount still needed. Fills
    ///      under `principalMin` are only permitted when they use up the offer completely. The hub verifies the
    ///      signature and records the fill. When the offer sets `FLAG_PARK_IDLE` and the hub has a reserve
    ///      adapter, the money is drawn from the parked vault position; otherwise it is pulled from the maker
    ///      with transferFrom.
    /// @param loanId Identifier of the loan being refinanced.
    /// @param offer A lend offer compatible with the loan; `_assertOfferMatchesLoan` lists the rules.
    /// @param signature EIP-712 signature by the maker over `offer`.
    function accept(uint256 loanId, LoanTypes.LendOffer calldata offer, bytes calldata signature) external nonReentrant {
        Rollover storage rollover = _activeRollover(loanId);
        if (block.timestamp > uint256(rollover.startedAt) + rollover.duration) revert AuctionEnded();

        uint16 rate = currentRate(loanId);
        if (offer.aprBps > rate) revert RateTooHigh(offer.aprBps, rate);
        // Every commitment becomes a slice when the rollover clears, so the slice cap is checked now instead of
        // letting a fully funded auction revert at the last step.
        if (_acceptances[loanId].length >= riskConfig.loanParams().maxSlicesPerLoan) revert TooManyAcceptances();

        LoanTypes.Loan memory loan = hub.getLoan(loanId);
        _assertOfferMatchesLoan(loanId, offer, loan);
        permissions.requireLender(offer.maker);

        (uint256 total, uint256 fee) = target(loanId);
        uint256 stillNeeded = total - rollover.accepted;
        uint256 capacity = hub.remainingCapacity(offer);
        uint256 fill = capacity < stillNeeded ? capacity : stillNeeded;
        if (fill == 0 || (fill < offer.principalMin && fill != capacity)) revert FillTooSmall();

        bytes32 digest = hub.consumeOffer(offer, signature, fill);
        _collectFunds(offer, loan.loanToken, fill);

        _acceptances[loanId].push(
            Acceptance({lender: offer.maker, amount: fill.toUint128(), rate: rate, flags: offer.flags, digest: digest})
        );
        rollover.accepted += fill.toUint128();
        emit RefinanceAccepted(loanId, offer.maker, fill, rate, rollover.accepted, total);

        if (rollover.accepted >= total) _settle(loanId, loan, total, fee);
    }

    /// @notice Ends a rollover whose window closed before the target was met. Open to any caller. All lenders are
    ///         refunded and the hub moves the loan to `Defaulted`.
    /// @dev Repayment remains possible on a defaulted loan, and a collateral auction can be opened on it no matter
    ///      how healthy it is.
    /// @param loanId Identifier of the loan whose rollover window has expired.
    function fail(uint256 loanId) external nonReentrant {
        Rollover storage rollover = _activeRollover(loanId);
        if (block.timestamp <= uint256(rollover.startedAt) + rollover.duration) revert AuctionNotEnded();
        (uint256 total,) = target(loanId);
        rollover.active = false;
        _refundAll(loanId, hub.getLoan(loanId).loanToken);
        hub.markDefaulted(loanId);
        emit RefinanceFailed(loanId, rollover.accepted, total);
    }

    /*//////////////////////////////////////////////////////////////
                           HUB CALLBACK
    //////////////////////////////////////////////////////////////*/

    /// @dev Restricted to the hub, which calls it from `beginLiquidation` when a loan with a running rollover is
    ///      sent to a collateral auction. Refunds all commitments and puts the loan back to `Active`, letting the
    ///      hub continue into `Liquidating`. Does nothing if there is no running rollover.
    function cancelForLiquidation(uint256 loanId) external {
        if (msg.sender != address(hub)) revert NotHub();
        Rollover storage rollover = rollovers[loanId];
        if (!rollover.active) return;
        rollover.active = false;
        _refundAll(loanId, hub.getLoan(loanId).loanToken);
        hub.cancelRefinance(loanId);
        emit RefinanceCancelledEvent(loanId);
    }

    /*//////////////////////////////////////////////////////////////
                              VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice The APR of a loan's current slices averaged by principal, in basis points. This is the rate any
    ///         rollover on the loan starts from. Returns zero for a loan without slices.
    /// @dev Weights use each slice's present principal. Partial repayments shrink every slice in proportion, so
    ///      they do not shift the average. The calculation sits in this contract rather than the hub because only
    ///      the rollover needs it, and the hub has no bytecode headroom left for extras.
    function blendedAprBps(uint256 loanId) public view returns (uint256) {
        uint256[] memory sliceIds = hub.getLoan(loanId).sliceIds;
        uint256 weightedSum;
        uint256 principalSum;
        for (uint256 idx; idx < sliceIds.length; ++idx) {
            LoanTypes.Slice memory slice = hub.getSlice(sliceIds[idx]);
            weightedSum += uint256(slice.principal) * slice.aprBps;
            principalSum += slice.principal;
        }
        return principalSum == 0 ? 0 : weightedSum / principalSum;
    }

    /// @notice The rate, in basis points, at which a lender would join at this moment. It climbs in a straight
    ///         line from `startRate` to `capRate` during the window and then stays at the cap.
    /// @dev Reverts if `loanId` has no running rollover.
    function currentRate(uint256 loanId) public view returns (uint16) {
        Rollover storage rollover = _activeRollover(loanId);
        uint256 elapsed = block.timestamp - rollover.startedAt;
        if (elapsed >= rollover.duration) return rollover.capRate;
        return (rollover.startRate + (uint256(rollover.capRate) - rollover.startRate) * elapsed / rollover.duration)
            .toUint16();
    }

    /// @notice The amount new lenders must put up: current principal and accrued interest, plus the rollover fee.
    /// @dev The fee is `refinanceBps` applied to principal. Since interest accrues every second, this figure rises
    ///      slowly through the window, and each commitment is measured against its value at that time.
    /// @return total Outstanding debt with the fee added.
    /// @return fee The fee component, sent to the fee vault on clearing.
    function target(uint256 loanId) public view returns (uint256 total, uint256 fee) {
        (uint256 principal, uint256 interest) = hub.debtOf(loanId);
        fee = principal * riskConfig.feeParams().refinanceBps / LoanTypes.BPS;
        total = principal + interest + fee;
    }

    /// @notice Reports whether `loanId` has a running rollover.
    function isActive(uint256 loanId) external view returns (bool) {
        return rollovers[loanId].active;
    }

    /// @notice The last second of the commitment window. `accept` still works at this timestamp, and `fail` is
    ///         available from the next one.
    /// @dev Reverts if `loanId` has no running rollover.
    function endsAt(uint256 loanId) external view returns (uint256) {
        Rollover storage rollover = _activeRollover(loanId);
        return uint256(rollover.startedAt) + rollover.duration;
    }

    /// @notice How much more must be committed before the rollover clears, namely the current target minus what
    ///         has been collected. It is also the largest fill the next commitment can make.
    /// @dev Reverts if `loanId` has no running rollover. Because interest keeps accruing on the existing loan,
    ///      the number grows slowly over the window.
    function shortfall(uint256 loanId) external view returns (uint256) {
        Rollover storage rollover = _activeRollover(loanId);
        (uint256 total,) = target(loanId);
        return total > rollover.accepted ? total - rollover.accepted : 0;
    }

    /// @notice Share of the current target already committed, in basis points and capped at 10,000. Meant for
    ///         progress bars, so a front end does not have to call `target` and read the rollover struct itself.
    /// @dev Reverts if `loanId` has no running rollover. Because the target keeps growing with interest, the
    ///      figure can dip slightly between commitments.
    function progressBps(uint256 loanId) external view returns (uint256) {
        Rollover storage rollover = _activeRollover(loanId);
        (uint256 total,) = target(loanId);
        if (total == 0 || rollover.accepted >= total) return LoanTypes.BPS;
        return uint256(rollover.accepted) * LoanTypes.BPS / total;
    }

    /// @notice Lists the funded commitments for `loanId`, oldest first. The list is empty after the rollover has
    ///         cleared, failed or been withdrawn.
    function acceptances(uint256 loanId) external view returns (Acceptance[] memory) {
        return _acceptances[loanId];
    }

    /*//////////////////////////////////////////////////////////////
                             INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev Loads the rollover for `loanId` and reverts with `NotActive` if it is not running.
    function _activeRollover(uint256 loanId) internal view returns (Rollover storage rollover) {
        rollover = rollovers[loanId];
        if (!rollover.active) revert NotActive();
    }

    /// @dev Enforces that an offer is suitable for the loan it would refinance. It must be on the lend side; name
    ///      either the loan's collateral token or that token's tier address; use the same loan token and term;
    ///      carry a `requestId` of zero or this loan's rollover key; and allow a `maxLtvBps` no lower than the
    ///      loan's present LTV, which the hub derives from the guard's price.
    /// @param loanId Identifier of the loan being refinanced.
    /// @param offer The offer being checked.
    /// @param loan The loan record the caller has already fetched.
    function _assertOfferMatchesLoan(uint256 loanId, LoanTypes.LendOffer calldata offer, LoanTypes.Loan memory loan)
        internal
        view
    {
        bytes32 digest = hub.offerHash(offer);
        uint8 tier = riskConfig.tokenConfig(loan.collateralToken).tier;
        bool collateralMatches =
            offer.collateralToken == loan.collateralToken || offer.collateralToken == address(uint160(tier));
        bytes32 rolloverKey = QuoteHash.rolloverKey(loanId);
        if (
            offer.side != LoanTypes.Side.Lend || !collateralMatches || offer.loanToken != loan.loanToken
                || offer.termSeconds != loan.termSeconds
                || (offer.requestId != bytes32(0) && offer.requestId != rolloverKey)
                || offer.maxLtvBps < hub.ltvBps(loanId)
        ) revert OfferMismatch(digest);
    }

    /// @dev Moves `fill` of the loan token from the offer's maker into this contract, drawing on the parked vault
    ///      position through the hub when the offer asks for that and a reserve adapter is configured.
    function _collectFunds(LoanTypes.LendOffer calldata offer, address loanToken, uint256 fill) internal {
        if (offer.flags & LoanTypes.FLAG_PARK_IDLE != 0 && address(hub.reserve()) != address(0)) {
            hub.pullFromIdle(offer.maker, fill, address(this));
        } else {
            IERC20(loanToken).safeTransferFrom(offer.maker, address(this), fill);
        }
    }

    /// @dev Converts the commitments into slice inputs, sends `total` to the hub and calls `clearRefinance`, which
    ///      pays off the departing lenders, takes the fee and mints the new slices for a term of the same length.
    ///      The rollover is flagged inactive before any outside call is made.
    function _settle(uint256 loanId, LoanTypes.Loan memory loan, uint256 total, uint256 fee) internal {
        rollovers[loanId].active = false;
        Acceptance[] storage commitments = _acceptances[loanId];
        LoanTypes.SliceInput[] memory inputs = new LoanTypes.SliceInput[](commitments.length);
        for (uint256 idx; idx < commitments.length; ++idx) {
            Acceptance storage entry = commitments[idx];
            inputs[idx] = LoanTypes.SliceInput({
                lender: entry.lender, principal: entry.amount, aprBps: entry.rate, flags: entry.flags
            });
        }
        IERC20(loan.loanToken).safeTransfer(address(hub), total);
        uint256[] memory sliceIds = hub.clearRefinance(loanId, inputs, loan.termSeconds, fee);
        delete _acceptances[loanId];
        emit RefinanceClearedEvent(loanId, total, fee, sliceIds);
    }

    /// @dev Returns every commitment to its lender, restores the capacity on the offer behind it, and clears the
    ///      list. Used by `cancelRefinance`, `fail` and `cancelForLiquidation`. A refunded lender has not lent
    ///      anything, so their signed offer must end up exactly as usable as before; without the release, an
    ///      unsuccessful rollover would silently eat into a live offer.
    function _refundAll(uint256 loanId, address loanToken) internal {
        Acceptance[] storage commitments = _acceptances[loanId];
        for (uint256 idx; idx < commitments.length; ++idx) {
            Acceptance storage entry = commitments[idx];
            hub.releaseOffer(entry.digest, entry.amount);
            IERC20(loanToken).safeTransfer(entry.lender, entry.amount);
        }
        delete _acceptances[loanId];
    }
}
