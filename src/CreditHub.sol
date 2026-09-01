// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {QuoteBook} from "./QuoteBook.sol";
import {ICreditHub} from "./interfaces/ICreditHub.sol";
import {IRiskConfig} from "./interfaces/IRiskConfig.sol";
import {IPermissionRegistry} from "./interfaces/IPermissionRegistry.sol";
import {IOracleGuard} from "./interfaces/IOracleGuard.sol";
import {ISliceNote} from "./interfaces/ISliceNote.sol";
import {IReserveAdapter} from "./interfaces/IReserveAdapter.sol";
import {LoanTypes, Permissions} from "./libraries/LoanTypes.sol";
import {InterestMath} from "./libraries/InterestMath.sol";

/// @dev The only function the hub ever calls on the rollover market. It asks the market to give up on a rollover
///      because the loan is about to be liquidated, and the market answers by calling back into
///      `cancelRefinance`.
interface IRolloverAbort {
    function cancelForLiquidation(uint256 loanId) external;
}

/// @title CreditHub
/// @notice The hub is the core of Spatial lending and holds every loan from start to finish. It verifies the
///         borrower's request and the lenders' signed offers, locks the collateral, sends the principal to the
///         borrower, records loans and slices, and applies payments. The liquidation auction and the rollover
///         market drive a loan through their processes using hooks set aside for them, while the slice note
///         reports changes of ownership so that payouts reach whoever holds each slice.
/// @dev Deployed once with no proxy and no owner. Governance touches the hub only through `wire`. Parameters are
///      read live from `riskConfig` on every use, never copied into local storage. No switch exists that can stop
///      repayment.
contract CreditHub is ICreditHub, QuoteBook, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using InterestMath for LoanTypes.Slice;

    /*//////////////////////////////////////////////////////////////
                          CONNECTED CONTRACTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Where all parameters come from, covering tiers, tokens, terms, fees, auction settings and pauses.
    IRiskConfig public immutable riskConfig;
    /// @notice Answers role checks for borrowers, lenders and relayers.
    IPermissionRegistry public immutable permissions;
    /// @notice Supplies prices, market session and staleness for each collateral token.
    IOracleGuard public immutable oracleGuard;
    /// @notice The ERC-721 whose token ids double as slice ids. A note is minted when a slice opens and burned
    ///         when it closes.
    ISliceNote public immutable sliceNote;
    /// @notice Collects the origination fee, the interest share, the rollover fee and the protocol's penalty
    ///         portion.
    address public immutable feeVault;

    /// @notice Fixed by `wire`. This and `rolloverMarket` are the two callers `onlyAuctions` lets through.
    address public liquidationAuction;
    /// @notice Fixed by `wire`. The hub only calls it to abort a rollover on a loan heading to liquidation.
    address public rolloverMarket;
    /// @notice May be left unset. If present, lenders with `FLAG_PARK_IDLE` are funded from, and repaid into,
    ///         the vault this adapter manages.
    IReserveAdapter public reserve;
    /// @notice Becomes true when `wire` runs, after which none of the three addresses above can be changed.
    bool public wired;

    /*//////////////////////////////////////////////////////////////
                             LEDGER STATE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICreditHub
    uint256 public override loanCount;
    /// @notice Number of slices ever created across all loans. Ids begin at 1 and are not recycled.
    uint256 public sliceCount;

    mapping(uint256 => LoanTypes.Loan) internal _loans;
    mapping(uint256 => LoanTypes.Slice) internal _slices;
    /// @notice Principal currently lent against each collateral token. A fill that would lift this above the
    ///         token's exposure cap in the risk config is refused at origination.
    mapping(address => uint256) public exposure;
    /// @inheritdoc ICreditHub
    mapping(bytes32 => bool) public override requestUsed;

    /*//////////////////////////////////////////////////////////////
                           HUB-ONLY ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @dev Only the owner of the risk config may call `wire`.
    error NotGovernance();
    /// @dev The reserve adapter passed to `wire` uses a vault the risk config has not approved.
    error VaultNotWhitelisted();
    /// @dev A slice named in the call is not part of the loan named in the same call.
    error SliceNotInLoan();
    /// @dev The principal of the incoming rollover slices does not equal the outgoing debt plus the fee.
    error SliceSumMismatch();
    /// @dev At the new principal the loan's health factor would be under one.
    error Unhealthy();

    /// @dev Lets only the liquidation auction or the rollover market through. Either one may reach any hook; the
    ///      status check inside each hook rules out calls that do not fit the loan's state.
    modifier onlyAuctions() {
        if (msg.sender != liquidationAuction && msg.sender != rolloverMarket) revert NotAuction();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                           SETUP AND WIRING
    //////////////////////////////////////////////////////////////*/

    /// @param riskConfig_ The risk config supplying parameters.
    /// @param permissions_ The permission registry consulted for roles.
    /// @param oracleGuard_ The guard that prices collateral.
    /// @param sliceNote_ The slice note contract the hub mints and burns on.
    /// @param feeVault_ Address that receives protocol fees.
    constructor(
        IRiskConfig riskConfig_,
        IPermissionRegistry permissions_,
        IOracleGuard oracleGuard_,
        ISliceNote sliceNote_,
        address feeVault_
    ) QuoteBook() {
        riskConfig = riskConfig_;
        permissions = permissions_;
        oracleGuard = oracleGuard_;
        sliceNote = sliceNote_;
        feeVault = feeVault_;
    }

    /// @notice Connects the liquidation auction, the rollover market and, if wanted, the reserve adapter. Only
    ///         the risk config's owner can call it, and only one time.
    /// @dev Each auction is built with the hub's address and the hub needs theirs in return, so this link is
    ///      made after all of them exist. A zero adapter turns idle parking off; a non-zero one must point at a
    ///      vault the risk config has approved.
    /// @param liquidationAuction_ The liquidation auction serving this hub.
    /// @param rolloverMarket_ The rollover market serving this hub.
    /// @param reserve_ The reserve adapter, or the zero address to go without.
    function wire(address liquidationAuction_, address rolloverMarket_, IReserveAdapter reserve_) external {
        if (msg.sender != riskConfig.owner()) revert NotGovernance();
        if (wired) revert AlreadyWired();
        if (address(reserve_) != address(0) && !riskConfig.vaultWhitelisted(reserve_.vault())) {
            revert VaultNotWhitelisted();
        }
        liquidationAuction = liquidationAuction_;
        rolloverMarket = rolloverMarket_;
        reserve = reserve_;
        wired = true;
        emit Wired(liquidationAuction_, rolloverMarket_, address(reserve_));
    }

    /*//////////////////////////////////////////////////////////////
                        BORROWER ENTRY POINTS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICreditHub
    /// @dev Steps, in order: the new-loans pause, the deadline and zero amounts; marking the request digest used;
    ///      checking a relayer; checking the borrower's role; the market checks against the risk config; pricing
    ///      the collateral and testing the LTV limit; writing the loan; drawing on the offers; and finally moving
    ///      tokens. Because collateral is only taken once every slice is recorded, a request that falls short
    ///      never pulls anything from the borrower.
    function originate(
        LoanTypes.BorrowRequest calldata request,
        bytes calldata borrowerSignature,
        LoanTypes.LendOffer[] calldata offers,
        bytes[] calldata signatures
    ) external override nonReentrant returns (uint256 loanId) {
        if (riskConfig.newLoansPaused()) revert NewLoansPaused();
        if (block.timestamp > request.fillDeadline) revert RequestExpired();
        if (request.principal == 0 || request.collateralAmount == 0) revert ZeroAmount();

        bytes32 reqDigest = requestHash(request);
        if (requestUsed[reqDigest]) revert RequestAlreadyUsed(reqDigest);
        requestUsed[reqDigest] = true;
        if (msg.sender != request.borrower) {
            permissions.requireRole(msg.sender, Permissions.RELAYER);
            if (!SignatureChecker.isValidSignatureNow(request.borrower, reqDigest, borrowerSignature)) {
                revert BadRequestSignature();
            }
        }
        permissions.requireRole(request.borrower, Permissions.BORROWER);

        uint8 tier = _gateMarket(request.collateralToken, request.loanToken, request.termSeconds, request.principal);
        uint256 ltv = _ltvAtOrigination(request.collateralToken, request.collateralAmount, request.principal, tier);

        loanId = ++loanCount;
        LoanTypes.Loan storage loan = _loans[loanId];
        loan.borrower = request.borrower;
        loan.collateralToken = request.collateralToken;
        loan.loanToken = request.loanToken;
        loan.collateralAmount = request.collateralAmount.toUint128();
        loan.principal = request.principal.toUint128();
        loan.startedAt = uint40(block.timestamp);
        loan.termSeconds = request.termSeconds;
        loan.maturity = uint40(block.timestamp + request.termSeconds);
        loan.status = LoanTypes.LoanStatus.Active;

        uint256 funded = _matchOffers(loanId, request, reqDigest, ltv, tier, offers, signatures);
        if (funded != request.principal) revert UnderFilled(funded, request.principal);

        exposure[request.collateralToken] += request.principal;
        IERC20(request.collateralToken).safeTransferFrom(request.borrower, address(this), request.collateralAmount);

        uint256 fee = request.principal * riskConfig.feeParams().originationBps / LoanTypes.BPS;
        if (fee > 0) IERC20(request.loanToken).safeTransfer(feeVault, fee);
        IERC20(request.loanToken).safeTransfer(request.borrower, request.principal - fee);

        emit LoanOriginated(
            loanId,
            request.borrower,
            request.collateralToken,
            request.loanToken,
            request.collateralAmount,
            request.principal,
            loan.maturity
        );
    }

    /// @inheritdoc ICreditHub
    /// @dev Flags the digest as used, just as funding would, so a relayer who has the signature can do nothing
    ///      with it. Reverts if the digest was already used for either reason.
    function cancelRequest(LoanTypes.BorrowRequest calldata request) external override {
        if (msg.sender != request.borrower) revert NotBorrower();
        bytes32 reqDigest = requestHash(request);
        if (requestUsed[reqDigest]) revert RequestAlreadyUsed(reqDigest);
        requestUsed[reqDigest] = true;
        emit RequestCancelled(msg.sender, reqDigest);
    }

    /// @inheritdoc ICreditHub
    /// @dev Open while the loan is Active or Defaulted: through the term, through the grace period, and after a
    ///      rollover has failed. Defaulted only differs in that an auction can start without a health check.
    ///      Loans that are Liquidating, Refinancing or closed refuse payment. Every slice is accrued, `amount`
    ///      is cut down to the total due, exactly that much is taken from the caller, interest is paid off
    ///      first, and the collateral goes back to the borrower once nothing is owed. Neither the guardian nor
    ///      governance has any way to switch this off.
    function repay(uint256 loanId, uint256 amount) external override nonReentrant {
        LoanTypes.Loan storage loan = _loans[loanId];
        if (!_repayable(loan.status)) revert BadStatus(loan.status);
        if (amount == 0) revert ZeroAmount();

        (uint256 interestDue, uint256 principalDue) = _accrueSlices(loan);
        uint256 totalDue = principalDue + interestDue;
        if (totalDue == 0) revert NothingToRepay();
        bool closing = amount >= totalDue;
        if (closing) amount = totalDue;

        IERC20(loan.loanToken).safeTransferFrom(msg.sender, address(this), amount);

        uint256 toInterest = amount < interestDue ? amount : interestDue;
        uint256 toPrincipal = amount - toInterest;
        _splitRepayment(loan, toInterest, toPrincipal, interestDue, principalDue, closing);

        // A loan's principal is the total of its slices, and exposure totals loan principal per collateral token,
        // so both drop by the principal just repaid. On a closing payment that takes the loan to zero.
        exposure[loan.collateralToken] -= toPrincipal;
        loan.principal -= toPrincipal.toUint128();
        if (closing) {
            loan.status = LoanTypes.LoanStatus.Repaid;
            uint256 escrowed = loan.collateralAmount;
            loan.collateralAmount = 0;
            IERC20(loan.collateralToken).safeTransfer(loan.borrower, escrowed);
            emit LoanRepaid(loanId, toInterest, toPrincipal);
        } else {
            emit LoanPartiallyRepaid(loanId, toInterest, toPrincipal);
        }
    }

    /// @inheritdoc ICreditHub
    /// @dev Allowed whenever a payment would be, and additionally during a rollover auction, which gives the
    ///      borrower a chance to improve the health factor before `clearRefinance` checks it at the new
    ///      principal.
    function addCollateral(uint256 loanId, uint256 amount) external override nonReentrant {
        LoanTypes.Loan storage loan = _loans[loanId];
        if (!_repayable(loan.status) && loan.status != LoanTypes.LoanStatus.Refinancing) revert BadStatus(loan.status);
        if (amount == 0) revert ZeroAmount();
        IERC20(loan.collateralToken).safeTransferFrom(msg.sender, address(this), amount);
        loan.collateralAmount += amount.toUint128();
        emit CollateralAdded(loanId, amount);
    }

    /*//////////////////////////////////////////////////////////////
                         OFFER LEDGER HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICreditHub
    /// @dev Fill tracking lives in the hub, so the rollover market records its acceptances here instead of
    ///      keeping its own tally. `_authenticateOffer` covers signature, expiry and nonce, and `_recordFill`
    ///      refuses anything beyond `principalMax`. Vetting the maker and moving tokens is the auction's job.
    function consumeOffer(LoanTypes.LendOffer calldata offer, bytes calldata signature, uint256 fill)
        external
        override
        onlyAuctions
        returns (bytes32 digest)
    {
        digest = _authenticateOffer(offer, signature);
        _recordFill(digest, offer, fill);
    }

    /// @inheritdoc ICreditHub
    /// @dev Undoes `consumeOffer` for acceptances the rollover market is refunding, using the digest that
    ///      `consumeOffer` returned at the time.
    function releaseOffer(bytes32 digest, uint256 amount) external override onlyAuctions {
        _releaseFill(digest, amount);
    }

    /*//////////////////////////////////////////////////////////////
                          LIQUIDATION HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICreditHub
    /// @dev When the loan is mid-rollover, the hub first tells the rollover market to drop it. That call comes
    ///      back in through `cancelRefinance` and restores Active before the status test that follows. Checking
    ///      health, the liquidation pause and closed-market rules is left to the auction.
    function beginLiquidation(uint256 loanId) external override onlyAuctions {
        LoanTypes.Loan storage loan = _loans[loanId];
        if (loan.status == LoanTypes.LoanStatus.Refinancing) {
            IRolloverAbort(rolloverMarket).cancelForLiquidation(loanId);
        }
        if (loan.status != LoanTypes.LoanStatus.Active && loan.status != LoanTypes.LoanStatus.Defaulted) {
            revert BadStatus(loan.status);
        }
        loan.status = LoanTypes.LoanStatus.Liquidating;
        emit LiquidationStarted(loanId);
    }

    /// @inheritdoc ICreditHub
    /// @dev Called when an auction starts during a closed market and some lenders have set
    ///      `FLAG_NO_CLOSED_MARKET_LIQUIDATION`. Those slices are pointed at a fresh loan that inherits the
    ///      borrower, tokens, start, maturity and term, and receives collateral in proportion to the principal it
    ///      takes over. The fresh loan begins Active and can be auctioned separately after the market opens.
    ///      Exposure does not change, since the principal only shifts between two loans on the same collateral.
    ///      Passing a slice twice, or one belonging elsewhere, causes a revert.
    function splitForLiquidation(uint256 loanId, uint256[] calldata keepSliceIds)
        external
        override
        onlyAuctions
        returns (uint256 newLoanId)
    {
        LoanTypes.Loan storage loan = _loans[loanId];
        _expectStatus(loan, LoanTypes.LoanStatus.Liquidating);

        newLoanId = ++loanCount;
        uint256 keptPrincipal;
        for (uint256 i = 0; i < keepSliceIds.length; i++) {
            LoanTypes.Slice storage slice = _slices[keepSliceIds[i]];
            if (slice.loanId != loanId) revert SliceNotInLoan();
            keptPrincipal += slice.principal;
            slice.loanId = newLoanId;
        }
        uint256 movedCollateral = uint256(loan.collateralAmount) * keptPrincipal / loan.principal;

        LoanTypes.Loan storage offshoot = _loans[newLoanId];
        offshoot.borrower = loan.borrower;
        offshoot.collateralToken = loan.collateralToken;
        offshoot.loanToken = loan.loanToken;
        offshoot.collateralAmount = movedCollateral.toUint128();
        offshoot.principal = keptPrincipal.toUint128();
        offshoot.startedAt = loan.startedAt;
        offshoot.maturity = loan.maturity;
        offshoot.termSeconds = loan.termSeconds;
        offshoot.status = LoanTypes.LoanStatus.Active;

        // Every kept slice now carries `newLoanId`, so one walk over the original list is enough to send each id
        // to the right loan while keeping the existing order in both lists.
        uint256[] memory remaining = new uint256[](loan.sliceIds.length - keepSliceIds.length);
        uint256 next;
        for (uint256 i = 0; i < loan.sliceIds.length; i++) {
            uint256 sid = loan.sliceIds[i];
            if (_slices[sid].loanId == newLoanId) offshoot.sliceIds.push(sid);
            else remaining[next++] = sid;
        }
        loan.sliceIds = remaining;
        loan.collateralAmount -= movedCollateral.toUint128();
        loan.principal -= keptPrincipal.toUint128();
        emit LoanSplit(loanId, newLoanId, movedCollateral, keepSliceIds);
    }

    /// @inheritdoc ICreditHub
    /// @dev Turns the slice's claim (principal plus unpaid interest) into a collateral amount at `price`, then
    ///      pays whichever is less: that amount, or the slice's principal-weighted portion of the escrow. The
    ///      limit stops one lender's exit in collateral from eating into what secures the remaining slices.
    ///      Collateral goes straight to the lender with no interest share deducted, and whatever the limit
    ///      leaves unpaid is written off when the slice is retired.
    function settleInKind(uint256 loanId, uint256 sliceId, uint256 price) external override onlyAuctions {
        LoanTypes.Loan storage loan = _loans[loanId];
        _expectStatus(loan, LoanTypes.LoanStatus.Liquidating);
        LoanTypes.Slice storage slice = _slices[sliceId];
        if (slice.loanId != loanId) revert SliceNotInLoan();

        slice.settleTo(uint40(block.timestamp));
        uint256 claim = uint256(slice.principal) + slice.owed();
        uint256 unit = 10 ** oracleGuard.collateralDecimals(loan.collateralToken);
        uint256 wanted = claim * unit / price;
        uint256 share = uint256(loan.collateralAmount) * slice.principal / loan.principal;
        uint256 amount = wanted < share ? wanted : share;

        exposure[loan.collateralToken] -= slice.principal;
        loan.principal -= slice.principal;
        loan.collateralAmount -= amount.toUint128();
        _dropSlice(loan, sliceId);
        address lender = slice.lender;
        _retireSlice(sliceId);
        IERC20(loan.collateralToken).safeTransfer(lender, amount);
        emit InKindLiquidation(loanId, sliceId, lender, amount, claim);
    }

    /// @inheritdoc ICreditHub
    /// @dev Touches nothing but the escrow. Debt, slices and exposure are dealt with in `finalizeLiquidation`
    ///      after the auction reports what it raised. The buyer's LIQUIDATOR role is checked by the auction
    ///      before this is called.
    function transferCollateral(uint256 loanId, address to, uint256 amount) external override onlyAuctions {
        LoanTypes.Loan storage loan = _loans[loanId];
        _expectStatus(loan, LoanTypes.LoanStatus.Liquidating);
        loan.collateralAmount -= amount.toUint128();
        IERC20(loan.collateralToken).safeTransfer(to, amount);
    }

    /// @inheritdoc ICreditHub
    /// @dev Expects `proceeds` to be held by the hub already. The penalty equals `penaltyBps` of the accrued
    ///      debt and is divided into keeper, lender and protocol portions using the risk config's auction
    ///      settings. Proceeds then flow down a waterfall, each step limited to what is left: the keeper's
    ///      portion, the lenders' claims, the lenders' penalty portion, the protocol's penalty portion, and any
    ///      remainder to the borrower. The protocol's interest share on recovered interest joins its penalty
    ///      portion in a single transfer to the fee vault. Leftover collateral returns to the borrower, exposure
    ///      falls by the principal still on the loan, and the loan is marked Settled even if lenders lost money.
    function finalizeLiquidation(uint256 loanId, uint256 proceeds, address keeper) external override onlyAuctions {
        LoanTypes.Loan storage loan = _loans[loanId];
        _expectStatus(loan, LoanTypes.LoanStatus.Liquidating);

        (uint256 interestDue, uint256 principalDue) = _accrueSlices(loan);
        uint256 debt = interestDue + principalDue;
        IRiskConfig.AuctionParams memory ap = riskConfig.auctionParams();
        uint256 penalty = debt * ap.penaltyBps / LoanTypes.BPS;
        uint256 keeperCut = penalty * ap.keeperShareBps / LoanTypes.BPS;
        uint256 lenderPenalty = (penalty - keeperCut) * ap.lenderPenaltyShareBps / LoanTypes.BPS;
        uint256 protocolPenalty = penalty - keeperCut - lenderPenalty;

        uint256 rest = proceeds;
        uint256 paidKeeper = _lesser(rest, keeperCut);
        rest -= paidKeeper;
        uint256 lenderPaid = _lesser(rest, debt);
        rest -= lenderPaid;
        uint256 lenderBonus = _lesser(rest, lenderPenalty);
        rest -= lenderBonus;
        uint256 paidProtocol = _lesser(rest, protocolPenalty);
        rest -= paidProtocol;

        uint256 interestShare = _distributeProceeds(loan, lenderPaid, lenderBonus, debt);
        paidProtocol += interestShare;

        address token = loan.loanToken;
        if (paidKeeper > 0) IERC20(token).safeTransfer(keeper, paidKeeper);
        if (paidProtocol > 0) IERC20(token).safeTransfer(feeVault, paidProtocol);
        if (rest > 0) IERC20(token).safeTransfer(loan.borrower, rest);

        uint256 unsold = loan.collateralAmount;
        loan.collateralAmount = 0;
        if (unsold > 0) IERC20(loan.collateralToken).safeTransfer(loan.borrower, unsold);

        exposure[loan.collateralToken] -= loan.principal;
        loan.principal = 0;
        loan.status = LoanTypes.LoanStatus.Settled;
        emit LiquidationFinalized(loanId, proceeds, paidKeeper, lenderPaid, paidProtocol, rest, debt - lenderPaid);
    }

    /*//////////////////////////////////////////////////////////////
                            ROLLOVER HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICreditHub
    /// @dev The rollover market passes on its own `msg.sender` as `caller`, and the hub requires that to be the
    ///      borrower. A rollover can only start on an Active loan that has not yet matured; once the grace period
    ///      has begun it is too late.
    function beginRefinance(uint256 loanId, address caller) external override onlyAuctions {
        LoanTypes.Loan storage loan = _loans[loanId];
        if (caller != loan.borrower) revert NotBorrower();
        _expectStatus(loan, LoanTypes.LoanStatus.Active);
        if (block.timestamp >= loan.maturity) revert BadStatus(loan.status);
        loan.status = LoanTypes.LoanStatus.Refinancing;
        emit RefinanceStarted(loanId);
    }

    /// @inheritdoc ICreditHub
    /// @dev Used both when the borrower backs out of a rollover and when `beginLiquidation` shuts one down. Only
    ///      the status is touched.
    function cancelRefinance(uint256 loanId) external override onlyAuctions {
        LoanTypes.Loan storage loan = _loans[loanId];
        _expectStatus(loan, LoanTypes.LoanStatus.Refinancing);
        loan.status = LoanTypes.LoanStatus.Active;
        emit RefinanceCancelled(loanId);
    }

    /// @inheritdoc ICreditHub
    /// @dev Before calling, the rollover market must have sent the hub loan token equal to
    ///      `sum(slices.principal)`, and that figure must match the outgoing debt plus `feeAmount`. The old slices
    ///      are paid off completely by `_splitRepayment`, which also deducts the interest share, and then
    ///      retired. The rollover fee is sent to the fee vault. After that the loan restarts at the new principal
    ///      with a new start and maturity, each new lender passes a role check and receives a slice, and the
    ///      loan must reach a health factor of one or more at the current quote, or everything reverts.
    function clearRefinance(uint256 loanId, LoanTypes.SliceInput[] calldata slices, uint32 newTerm, uint256 feeAmount)
        external
        override
        onlyAuctions
        returns (uint256[] memory sliceIds)
    {
        LoanTypes.Loan storage loan = _loans[loanId];
        _expectStatus(loan, LoanTypes.LoanStatus.Refinancing);
        if (!riskConfig.termAllowed(newTerm)) revert TermNotAllowed(newTerm);

        (uint256 interestDue, uint256 principalDue) = _accrueSlices(loan);
        uint256 outgoingDebt = interestDue + principalDue;

        uint256 incomingPrincipal;
        for (uint256 i = 0; i < slices.length; i++) {
            incomingPrincipal += slices[i].principal;
        }
        if (incomingPrincipal != outgoingDebt + feeAmount) revert SliceSumMismatch();

        // Settle the old lenders completely and close out their slices.
        _splitRepayment(loan, interestDue, principalDue, interestDue, principalDue, true);
        if (feeAmount > 0) IERC20(loan.loanToken).safeTransfer(feeVault, feeAmount);

        // Start the loan over for the new lenders, replacing old principal with new in the exposure total.
        exposure[loan.collateralToken] = exposure[loan.collateralToken] - principalDue + incomingPrincipal;
        loan.principal = incomingPrincipal.toUint128();
        loan.startedAt = uint40(block.timestamp);
        loan.termSeconds = newTerm;
        loan.maturity = uint40(block.timestamp + newTerm);
        loan.status = LoanTypes.LoanStatus.Active;

        sliceIds = new uint256[](slices.length);
        for (uint256 i = 0; i < slices.length; i++) {
            permissions.requireLender(slices[i].lender);
            sliceIds[i] = _issueSlice(loanId, slices[i].lender, slices[i].principal, slices[i].aprBps, slices[i].flags);
        }

        if (healthFactor(loanId) < LoanTypes.WAD) revert Unhealthy();
        emit RefinanceCleared(loanId, incomingPrincipal, loan.maturity);
    }

    /// @inheritdoc ICreditHub
    /// @dev The rollover market calls this once the rate has climbed to its cap and acceptances still fall short
    ///      of the debt. At that point the loan may be either Active or Refinancing. A Defaulted loan keeps
    ///      taking payments and top-ups; the difference is that a liquidation can begin whatever its health.
    function markDefaulted(uint256 loanId) external override onlyAuctions {
        LoanTypes.Loan storage loan = _loans[loanId];
        if (loan.status != LoanTypes.LoanStatus.Refinancing && loan.status != LoanTypes.LoanStatus.Active) {
            revert BadStatus(loan.status);
        }
        loan.status = LoanTypes.LoanStatus.Defaulted;
        emit LoanDefaulted(loanId);
    }

    /// @inheritdoc ICreditHub
    /// @dev The reserve adapter will only release parked funds to the hub, so the rollover market sends its
    ///      on-demand withdrawals for `FLAG_PARK_IDLE` acceptances through this function. Reverts when no adapter
    ///      has been wired.
    function pullFromIdle(address lender, uint256 amount, address to) external override onlyAuctions {
        reserve.withdrawFor(lender, amount, to);
    }

    /*//////////////////////////////////////////////////////////////
                            SLICE NOTE HOOK
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICreditHub
    /// @dev Whoever holds the note owns the slice. The slice note has already confirmed that `to` holds a lender
    ///      role before calling, and the hub just switches the payee so payments, collateral payouts and auction
    ///      proceeds reach the new holder. Mints and burns never come through here, only transfers between
    ///      holders.
    function onSliceTransfer(uint256 sliceId, address to) external override {
        if (msg.sender != address(sliceNote)) revert NotSliceNote();
        LoanTypes.Slice storage slice = _slices[sliceId];
        address from = slice.lender;
        slice.lender = to;
        emit SliceTransferred(slice.loanId, sliceId, to, from);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICreditHub
    function getLoan(uint256 loanId) external view override returns (LoanTypes.Loan memory) {
        return _loans[loanId];
    }

    /// @inheritdoc ICreditHub
    function getSlice(uint256 sliceId) external view override returns (LoanTypes.Slice memory) {
        return _slices[sliceId];
    }

    /// @inheritdoc ICreditHub
    /// @dev Goes through `owedAt`, which carries interest forward to this second without any storage writes.
    function debtOf(uint256 loanId) public view override returns (uint256 principal, uint256 interest) {
        LoanTypes.Loan storage loan = _loans[loanId];
        uint40 nowTs = uint40(block.timestamp);
        for (uint256 i = 0; i < loan.sliceIds.length; i++) {
            LoanTypes.Slice storage slice = _slices[loan.sliceIds[i]];
            principal += slice.principal;
            interest += slice.owedAt(nowTs);
        }
    }

    /// @inheritdoc ICreditHub
    /// @dev Computed as `value * liqLtv / debt` in WAD, where `liqLtv` comes from the tier of the collateral
    ///      token. If the quote is stale or from a closed session, the tier's closed-market haircut is taken off
    ///      the liquidation LTV beforehand, pulling down the health factor of every loan against that token.
    function healthFactor(uint256 loanId) public view override returns (uint256) {
        (uint256 debt, uint256 value, bool haircut) = _markToMarket(loanId);
        if (debt == 0) return type(uint256).max;
        address token = _loans[loanId].collateralToken;
        IRiskConfig.TierConfig memory cfg = riskConfig.tierConfig(riskConfig.tokenConfig(token).tier);
        uint256 liqLtv = haircut ? cfg.liqLtvBps - cfg.closedHaircutBps : cfg.liqLtvBps;
        return value * liqLtv * LoanTypes.WAD / (LoanTypes.BPS * debt);
    }

    /// @inheritdoc ICreditHub
    function ltvBps(uint256 loanId) external view override returns (uint256) {
        (uint256 debt, uint256 value,) = _markToMarket(loanId);
        return value == 0 ? type(uint256).max : debt * LoanTypes.BPS / value;
    }

    /*//////////////////////////////////////////////////////////////
                       INTERNAL LEDGER HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Works through the offers in the order supplied until the request is covered. For each one it
    ///      authenticates the offer, checks it against the request, sizes the fill as the lesser of what the
    ///      offer has left and what the request still needs, records it, collects the funds and mints a slice,
    ///      all before moving on. Fills under `principalMin` are only accepted if they drain the offer. An offer
    ///      that turns up once the request is already covered causes a revert instead of being passed over.
    /// @return funded Sum of principal drawn from all offers, which the caller requires to equal the request.
    function _matchOffers(
        uint256 loanId,
        LoanTypes.BorrowRequest calldata request,
        bytes32 reqDigest,
        uint256 ltv,
        uint8 tier,
        LoanTypes.LendOffer[] calldata offers,
        bytes[] calldata signatures
    ) internal returns (uint256 funded) {
        if (offers.length != signatures.length) revert LengthMismatch();
        for (uint256 i = 0; i < offers.length; i++) {
            LoanTypes.LendOffer calldata offer = offers[i];
            bytes32 digest = _authenticateOffer(offer, signatures[i]);
            _checkOfferTerms(offer, digest, request, reqDigest, ltv, tier);

            uint256 stillNeeded = request.principal - funded;
            if (stillNeeded == 0) revert OverFilled();
            uint256 capacity = _remainingCapacity(digest, offer.principalMax);
            if (capacity == 0) revert OfferExhausted(digest);
            uint256 fill = capacity < stillNeeded ? capacity : stillNeeded;
            if (fill < offer.principalMin && fill != capacity) revert FillTooSmall(digest);

            permissions.requireLender(offer.maker);
            _recordFill(digest, offer, fill);
            _collectPrincipal(offer.maker, request.loanToken, fill, offer.flags);
            _issueSlice(loanId, offer.maker, fill, offer.aprBps, offer.flags);
            funded += fill;
        }
    }

    /// @dev Brings `amount` of loan token into the hub. Lenders with `FLAG_PARK_IDLE` are paid out of their
    ///      vault position via the reserve adapter if one is wired; all others are charged against the allowance
    ///      on their wallet.
    function _collectPrincipal(address lender, address loanToken, uint256 amount, uint8 flags) internal {
        if (flags & LoanTypes.FLAG_PARK_IDLE != 0 && address(reserve) != address(0)) {
            reserve.withdrawFor(lender, amount, address(this));
        } else {
            IERC20(loanToken).safeTransferFrom(lender, address(this), amount);
        }
    }

    /// @dev Creates the slice record, adds it to the loan's list and mints its note to the lender. Applies the
    ///      risk config's cap on slices per loan, and sets the slice's minimum interest to what `principal` earns
    ///      at `aprBps` across the minimum interest period, which an early payoff still has to cover.
    /// @return sliceId The new slice's id, which is also its note's token id.
    function _issueSlice(uint256 loanId, address lender, uint256 principal, uint16 aprBps, uint8 flags)
        internal
        returns (uint256 sliceId)
    {
        IRiskConfig.LoanParams memory lp = riskConfig.loanParams();
        if (_loans[loanId].sliceIds.length >= lp.maxSlicesPerLoan) revert TooManySlices(lp.maxSlicesPerLoan);

        sliceId = ++sliceCount;
        uint256 floorInterest = InterestMath.linear(principal, aprBps, lp.minInterestPeriod);
        _slices[sliceId] = LoanTypes.Slice({
            loanId: loanId,
            lender: lender,
            principal: principal.toUint128(),
            minInterest: floorInterest.toUint128(),
            accruedInterest: 0,
            interestPaid: 0,
            lastAccrual: uint40(block.timestamp),
            aprBps: aprBps,
            flags: flags
        });
        _loans[loanId].sliceIds.push(sliceId);
        sliceNote.mint(lender, sliceId);
        emit SliceCreated(loanId, sliceId, lender, principal, aprBps, flags);
    }

    /// @dev Brings every slice's accrual up to this block and adds up the loan's obligations.
    /// @return interestDue Total unpaid interest, with each slice held to at least its minimum interest.
    /// @return principalDue Total principal still lent across the slices.
    function _accrueSlices(LoanTypes.Loan storage loan) internal returns (uint256 interestDue, uint256 principalDue) {
        uint40 nowTs = uint40(block.timestamp);
        uint256 count = loan.sliceIds.length;
        for (uint256 i = 0; i < count; i++) {
            LoanTypes.Slice storage slice = _slices[loan.sliceIds[i]];
            slice.settleTo(nowTs);
            interestDue += slice.owed();
            principalDue += slice.principal;
        }
    }

    /// @dev Divides a payment among the slices. The interest part goes by each slice's share of the interest
    ///      due, and the principal part by each slice's share of the principal due. A lender receives their
    ///      interest minus the protocol's interest share, plus their principal, and all of the protocol's share
    ///      goes to the fee vault in a single transfer. With `closing` set, each slice is retired and the loan's
    ///      list emptied, leaving the caller to zero the loan's principal. `_accrueSlices` must have run earlier
    ///      in the same call.
    ///
    ///      Each slice's portion comes from cumulative totals: the payment is pro-rated over all the debt seen up
    ///      to and including this slice, and what earlier slices received is subtracted. Because the final
    ///      cumulative total is the whole debt, the portions add up exactly to `toInterest` and `toPrincipal`,
    ///      and no slice is ever given more than it is owed. Truncating each slice on its own and handing the
    ///      leftover to the final one would stack every rounding loss on that slice, and a payment just under the
    ///      full debt could then try to take more principal from it than it had.
    function _splitRepayment(
        LoanTypes.Loan storage loan,
        uint256 toInterest,
        uint256 toPrincipal,
        uint256 interestDue,
        uint256 principalDue,
        bool closing
    ) internal {
        uint256 count = loan.sliceIds.length;
        uint256 shareBps = riskConfig.feeParams().interestShareBps;
        uint256 interestGiven;
        uint256 principalGiven;
        uint256 interestCum;
        uint256 principalCum;
        uint256 feeTotal;
        for (uint256 i = 0; i < count; i++) {
            uint256 sliceId = loan.sliceIds[i];
            LoanTypes.Slice storage slice = _slices[sliceId];
            interestCum += slice.owed();
            principalCum += slice.principal;
            uint256 sliceInterest;
            uint256 slicePrincipal;
            // The cumulative figures never shrink, so these subtractions cannot underflow.
            unchecked {
                if (interestDue != 0) sliceInterest = toInterest * interestCum / interestDue - interestGiven;
                if (principalDue != 0) slicePrincipal = toPrincipal * principalCum / principalDue - principalGiven;
            }
            interestGiven += sliceInterest;
            principalGiven += slicePrincipal;
            slice.interestPaid += sliceInterest.toUint128();
            slice.principal -= slicePrincipal.toUint128();
            uint256 fee = sliceInterest * shareBps / LoanTypes.BPS;
            feeTotal += fee;
            _routeToLender(slice.lender, loan.loanToken, sliceInterest - fee + slicePrincipal, slice.flags);
            if (closing) _retireSlice(sliceId);
        }
        if (closing) delete loan.sliceIds;
        if (feeTotal > 0) IERC20(loan.loanToken).safeTransfer(feeVault, feeTotal);
    }

    /// @dev Divides `lenderPaid + lenderBonus` among the slices according to each one's claim as a fraction of
    ///      `debt`, giving any rounding leftover to the final slice. Each lender is paid via `_routeToLender` and
    ///      every slice is retired. The caller sends the returned interest share on to the fee vault.
    /// @return feeTotal The protocol's interest share added up over all slices, with each slice's part capped
    ///         at that slice's payout.
    function _distributeProceeds(LoanTypes.Loan storage loan, uint256 lenderPaid, uint256 lenderBonus, uint256 debt)
        internal
        returns (uint256 feeTotal)
    {
        uint256 count = loan.sliceIds.length;
        uint256 shareBps = riskConfig.feeParams().interestShareBps;
        uint256 paidSoFar;
        for (uint256 i = 0; i < count; i++) {
            uint256 sliceId = loan.sliceIds[i];
            LoanTypes.Slice storage slice = _slices[sliceId];
            uint256 claim = uint256(slice.principal) + slice.owed();
            uint256 pay;
            if (i == count - 1) {
                pay = lenderPaid + lenderBonus - paidSoFar;
            } else {
                pay = debt == 0 ? 0 : (lenderPaid + lenderBonus) * claim / debt;
            }
            paidSoFar += pay;
            // Assume interest came back at the same rate as the debt as a whole, and charge the share only on
            // that recovered amount, not on interest the auction did not manage to raise.
            uint256 interestRecovered = debt == 0 ? 0 : lenderPaid * slice.owed() / debt;
            uint256 fee = interestRecovered * shareBps / LoanTypes.BPS;
            if (fee > pay) fee = pay;
            feeTotal += fee;
            _routeToLender(slice.lender, loan.loanToken, pay - fee, slice.flags);
            _retireSlice(sliceId);
        }
        delete loan.sliceIds;
    }

    /// @dev Sends a payout to a lender. If the slice has `FLAG_PARK_IDLE` and an adapter is wired, the tokens are
    ///      deposited into the vault for the lender; otherwise they are transferred straight to the lender's
    ///      address. Does nothing for a zero amount.
    function _routeToLender(address lender, address loanToken, uint256 amount, uint8 flags) internal {
        if (amount == 0) return;
        if (flags & LoanTypes.FLAG_PARK_IDLE != 0 && address(reserve) != address(0)) {
            IERC20(loanToken).forceApprove(address(reserve), amount);
            reserve.depositFor(lender, amount);
        } else {
            IERC20(loanToken).safeTransfer(lender, amount);
        }
    }

    /// @dev Burns the slice's note and clears its record. The caller is responsible for taking the id off the
    ///      loan's list, whether by removing that single entry or wiping the list.
    function _retireSlice(uint256 sliceId) internal {
        sliceNote.burn(sliceId);
        delete _slices[sliceId];
    }

    /// @dev Takes one id out of a loan's slice list by overwriting it with the final entry and popping. The list
    ///      order is not kept. Reverts when the id is not found.
    function _dropSlice(LoanTypes.Loan storage loan, uint256 sliceId) internal {
        uint256 count = loan.sliceIds.length;
        for (uint256 i = 0; i < count; i++) {
            if (loan.sliceIds[i] == sliceId) {
                loan.sliceIds[i] = loan.sliceIds[count - 1];
                loan.sliceIds.pop();
                return;
            }
        }
        revert SliceNotInLoan();
    }

    /// @dev Reverts with the loan's current status if it differs from `expected`.
    function _expectStatus(LoanTypes.Loan storage loan, LoanTypes.LoanStatus expected) internal view {
        if (loan.status != expected) revert BadStatus(loan.status);
    }

    /// @dev True for Active and Defaulted, the two states in which the debt can still be paid off directly.
    ///      Payment stops being possible once an auction begins or the loan has closed.
    function _repayable(LoanTypes.LoanStatus status) internal pure returns (bool) {
        return status == LoanTypes.LoanStatus.Active || status == LoanTypes.LoanStatus.Defaulted;
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL CHECKS AND PRICING MATHS
    //////////////////////////////////////////////////////////////*/

    /// @dev Risk config checks that do not need a price. The term must be allowed, both tokens must be enabled,
    ///      the loan token must be the one the collateral's feed quotes in, and the collateral token's exposure
    ///      cap must have space for `principal`.
    ///
    ///      The guard reports prices in base units of whichever loan token the feed was set up for, and the LTV
    ///      check divides principal by that value. Without the quote token check, enabling another loan token
    ///      would allow collateral to be paired with a token of different decimals, throwing the LTV off by that
    ///      scale in one direction or the other.
    /// @return tier The collateral token's risk tier in the risk config, which determines its LTV limits.
    function _gateMarket(address collateralToken, address loanToken, uint32 termSeconds, uint256 principal)
        internal
        view
        returns (uint8 tier)
    {
        if (!riskConfig.termAllowed(termSeconds)) revert TermNotAllowed(termSeconds);
        if (!riskConfig.loanTokenEnabled(loanToken)) revert TokenNotEnabled(loanToken);
        address quoted = oracleGuard.quoteToken(collateralToken);
        if (loanToken != quoted) revert LoanTokenMismatch(loanToken, quoted);
        IRiskConfig.TokenConfig memory cfg = riskConfig.tokenConfig(collateralToken);
        if (!cfg.enabled) revert TokenNotEnabled(collateralToken);
        if (exposure[collateralToken] + principal > cfg.exposureCap) revert ExposureCapExceeded(collateralToken);
        tier = cfg.tier;
    }

    /// @dev Gets a price from `oracleGuard.refresh`, which also stores a move-cap checkpoint, and compares the
    ///      request's LTV with the tier limit. The request fails if the guard is paused, the collateral is worth
    ///      zero, or the price is stale while the market is open. A stale price during a closed market is
    ///      allowed but triggers the closed-market haircut, as does any quote taken in a closed session.
    /// @return ltv Principal requested divided by collateral value, in basis points.
    function _ltvAtOrigination(address collateralToken, uint256 collateralAmount, uint256 principal, uint8 tier)
        internal
        returns (uint256 ltv)
    {
        IOracleGuard.Quote memory snap = oracleGuard.refresh(collateralToken);
        if (snap.paused) revert OracleUnusable();
        // Liquidations stay blocked until the sequencer grace period ends. Writing a loan during that window
        // would rest on a price no one has yet been able to trade on or dispute, and if it turned out wrong no
        // one could respond, so new loans are held back for the same period.
        if (snap.sequencerGrace) revert SequencerGrace();
        bool haircut = snap.session == LoanTypes.Session.Closed || snap.stale;
        if (snap.stale && snap.session != LoanTypes.Session.Closed) revert OracleUnusable();

        uint256 value = _valueCollateral(collateralToken, collateralAmount, snap.price);
        if (value == 0) revert OracleUnusable();
        ltv = principal * LoanTypes.BPS / value;

        IRiskConfig.TierConfig memory cfg = riskConfig.tierConfig(tier);
        uint256 ceiling = haircut ? cfg.maxLtvBps - cfg.closedHaircutBps : cfg.maxLtvBps;
        if (ltv > ceiling) revert LtvTooHigh(ltv, ceiling);
    }

    /// @dev Decides whether an offer can fund the request. It must be a lend offer; its collateral token must be
    ///      the request's own or the tier wildcard `address(uint160(tier))`; loan token and term must match; its
    ///      rate must not exceed the borrower's cap; its LTV limit must be at least the request's LTV; and its
    ///      `requestId` must be zero or equal to the request digest. Touches no storage.
    function _checkOfferTerms(
        LoanTypes.LendOffer calldata offer,
        bytes32 digest,
        LoanTypes.BorrowRequest calldata request,
        bytes32 reqDigest,
        uint256 ltv,
        uint8 tier
    ) internal pure {
        if (offer.side != LoanTypes.Side.Lend) revert OfferSideNotSupported();
        bool collateralMatches =
            offer.collateralToken == request.collateralToken || offer.collateralToken == address(uint160(tier));
        if (
            !collateralMatches || offer.loanToken != request.loanToken || offer.termSeconds != request.termSeconds
                || offer.aprBps > request.maxAprBps || offer.maxLtvBps < ltv
                || (offer.requestId != bytes32(0) && offer.requestId != reqDigest)
        ) revert OfferMismatch(digest);
    }

    /// @dev Common inputs for the two risk views: debt including interest to this second, collateral value at the
    ///      guard's read-only quote (so no checkpoint is stored), and whether that quote calls for the
    ///      closed-market haircut.
    function _markToMarket(uint256 loanId) internal view returns (uint256 debt, uint256 value, bool haircut) {
        LoanTypes.Loan storage loan = _loans[loanId];
        (uint256 p, uint256 i) = debtOf(loanId);
        debt = p + i;
        IOracleGuard.Quote memory snap = oracleGuard.quote(loan.collateralToken);
        value = _valueCollateral(loan.collateralToken, loan.collateralAmount, snap.price);
        haircut = snap.session == LoanTypes.Session.Closed || snap.stale;
    }

    /// @dev Worth of `amount` collateral at `price`, given in loan-token base units. `price` is quoted per whole
    ///      collateral token, and the guard provides the decimals needed to scale `amount`.
    function _valueCollateral(address collateralToken, uint256 amount, uint256 price) internal view returns (uint256) {
        return amount * price / (10 ** oracleGuard.collateralDecimals(collateralToken));
    }

    function _lesser(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
