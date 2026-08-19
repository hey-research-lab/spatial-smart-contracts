// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LoanTypes} from "../libraries/LoanTypes.sol";

/// @title ICreditHub
/// @notice External surface of the hub. Borrowers and lenders use it to open and pay down loans, the liquidation
///         auction, the rollover market and the slice note each get a set of restricted hooks, and anyone can
///         read the loan and slice records.
/// @dev Token amounts are always in the smallest unit of the token concerned and rates are in basis points.
///      Health factors use 18-decimal fixed point, where 1e18 stands for 1.0.
interface ICreditHub {
    /*//////////////////////////////////////////////////////////////
                         ORIGINATION EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice A borrow request has been fully funded and the loan has started. Each slice behind it is announced
    ///         separately by a `SliceCreated` event tagged with the same loan id.
    /// @param loanId Identifier assigned to the loan.
    /// @param borrower Account that supplied the collateral and carries the debt.
    /// @param collateralToken Token placed in escrow.
    /// @param loanToken Token in which principal was paid out.
    /// @param collateralAmount Size of the escrow when the loan opened.
    /// @param principal Gross amount owed; the borrower was paid this minus the origination fee.
    /// @param maturity Moment the term runs out and the grace period starts.
    event LoanOriginated(
        uint256 indexed loanId,
        address indexed borrower,
        address indexed collateralToken,
        address loanToken,
        uint256 collateralAmount,
        uint256 principal,
        uint40 maturity
    );
    /// @notice A lender's share of a loan was recorded and the matching slice note was minted.
    /// @param sliceId Identifier of the slice, shared with its note.
    /// @param lender Owner of the slice when it was created.
    /// @param principal Principal supplied through this slice.
    /// @param aprBps Annual rate the slice earns, fixed for its life.
    /// @param flags Flag bits carried over from the lender's offer, as defined in LoanTypes.
    event SliceCreated(
        uint256 indexed loanId,
        uint256 indexed sliceId,
        address indexed lender,
        uint256 principal,
        uint16 aprBps,
        uint8 flags
    );
    /// @notice A borrower used up their own signed request so it can no longer be relayed.
    event RequestCancelled(address indexed borrower, bytes32 indexed requestHash);
    /// @notice The hub was linked to both auctions and to the reserve adapter. Happens exactly once.
    event Wired(address liquidationAuction, address rolloverMarket, address reserve);

    /*//////////////////////////////////////////////////////////////
                          SERVICING EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Extra collateral went into the escrow of an open loan.
    event CollateralAdded(uint256 indexed loanId, uint256 amount);
    /// @notice A payment lowered the debt but left the loan open.
    /// @param interestPaid Amount put towards interest, counted before the protocol takes its interest share.
    /// @param principalPaid Amount put towards principal.
    event LoanPartiallyRepaid(uint256 indexed loanId, uint256 interestPaid, uint256 principalPaid);
    /// @notice A payment cleared the whole debt and the borrower got the escrow back.
    /// @param interestPaid Interest covered by this last payment, counted before the protocol's share.
    /// @param principalPaid Principal covered by this last payment.
    event LoanRepaid(uint256 indexed loanId, uint256 interestPaid, uint256 principalPaid);
    /// @notice A slice note moved to a new holder, who now collects everything the slice pays out.
    event SliceTransferred(uint256 indexed loanId, uint256 indexed sliceId, address indexed to, address from);

    /*//////////////////////////////////////////////////////////////
                         LIQUIDATION EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice The liquidation auction has taken over the loan, and payments are no longer accepted.
    event LiquidationStarted(uint256 indexed loanId);
    /// @notice Slices that refuse closed-market liquidation were moved onto a new loan, taking collateral in line
    ///         with their share of principal.
    /// @param loanId The loan that remains under liquidation.
    /// @param newLoanId The newly created Active loan holding the moved slices.
    /// @param collateralMoved Amount of collateral shifted onto the new loan.
    /// @param sliceIds The moved slices, in the order the auction passed them.
    event LoanSplit(uint256 indexed loanId, uint256 indexed newLoanId, uint256 collateralMoved, uint256[] sliceIds);
    /// @notice A lender who chose settlement in collateral was paid that way and the slice was closed.
    /// @param collateralAmount Collateral sent to the lender.
    /// @param claim The slice's principal and interest due at the moment of settlement.
    event InKindLiquidation(
        uint256 indexed loanId, uint256 indexed sliceId, address indexed lender, uint256 collateralAmount, uint256 claim
    );
    /// @notice The auction's proceeds were shared out and the loan ended as Settled.
    /// @param proceeds Loan token the auction passed to the hub.
    /// @param keeperShare Amount paid to the keeper that ran the auction.
    /// @param lenderPaid Amount credited against lender claims, before the lenders' penalty portion and before
    ///        the interest share is taken.
    /// @param penaltyToProtocol The protocol's portion of the penalty together with its interest share on the
    ///        interest that was recovered.
    /// @param surplus Loan token passed back to the borrower.
    /// @param shortfall Part of the lenders' claims that went unpaid.
    event LiquidationFinalized(
        uint256 indexed loanId,
        uint256 proceeds,
        uint256 keeperShare,
        uint256 lenderPaid,
        uint256 penaltyToProtocol,
        uint256 surplus,
        uint256 shortfall
    );

    /*//////////////////////////////////////////////////////////////
                           ROLLOVER EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice The borrower started a rollover auction ahead of maturity.
    event RefinanceStarted(uint256 indexed loanId);
    /// @notice The rollover auction was called off, leaving the loan Active on the terms it already had.
    event RefinanceCancelled(uint256 indexed loanId);
    /// @notice A rollover completed: the old lenders were paid out and a new term started. Each new slice is
    ///         announced separately by `SliceCreated`.
    /// @param newPrincipal Amount owed to the new lenders, which folds in the accrued interest and the rollover
    ///        fee.
    /// @param newMaturity Moment the new term ends.
    event RefinanceCleared(uint256 indexed loanId, uint256 newPrincipal, uint40 newMaturity);
    /// @notice The loan is now Defaulted. It may be sent to auction without a health check, and it can still be
    ///         repaid.
    event LoanDefaulted(uint256 indexed loanId);

    /*//////////////////////////////////////////////////////////////
                          ACCESS ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @dev Only the borrower named on the loan or the request may do this.
    error NotBorrower();
    /// @dev Only the liquidation auction or the rollover market may call this hook.
    error NotAuction();
    /// @dev Only the slice note contract may call this hook.
    error NotSliceNote();
    /// @dev The hub has already been wired.
    error AlreadyWired();

    /*//////////////////////////////////////////////////////////////
                      REQUEST AND MARKET ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @dev New loans are switched off in the risk config. Payments still go through.
    error NewLoansPaused();
    /// @dev The request is past its fill deadline.
    error RequestExpired();
    /// @dev This request digest has already been used, either to fund a loan or by cancellation.
    error RequestAlreadyUsed(bytes32 requestHash);
    /// @dev A relayed request did not carry a valid signature from the borrower.
    error BadRequestSignature();
    /// @dev The risk config does not list this term as allowed.
    error TermNotAllowed(uint32 termSeconds);
    /// @dev The risk config has not enabled this loan token or collateral token.
    error TokenNotEnabled(address token);
    /// @dev The request's loan token differs from the token the collateral's price feed is quoted in, which
    ///      would make the LTV figure meaningless.
    error LoanTokenMismatch(address loanToken, address quoteToken);
    /// @dev Funding this request would carry the collateral token's lent principal above its exposure cap.
    error ExposureCapExceeded(address token);
    /// @dev The request's LTV exceeds the tier's limit, including any closed-market haircut.
    error LtvTooHigh(uint256 ltvBps, uint256 maxLtvBps);
    /// @dev One of the amount arguments was zero.
    error ZeroAmount();

    /*//////////////////////////////////////////////////////////////
                           MATCHING ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @dev The offer disagrees with the request on token, term, rate, LTV limit or request binding.
    error OfferMismatch(bytes32 offerHash);
    /// @dev The offer is not a lend-side offer, and only those can be filled.
    error OfferSideNotSupported();
    /// @dev The fill falls short of the offer's `principalMin` without using up the rest of the offer.
    error FillTooSmall(bytes32 offerHash);
    /// @dev The supplied offers together come to less than the principal requested.
    error UnderFilled(uint256 filled, uint256 wanted);
    /// @dev An offer was supplied after the request had already been fully covered.
    error OverFilled();
    /// @dev Nothing is left of the offer's `principalMax`.
    error OfferExhausted(bytes32 offerHash);
    /// @dev The `offers` and `signatures` arrays are not the same length.
    error LengthMismatch();
    /// @dev The loan already holds as many slices as the risk config permits.
    error TooManySlices(uint256 max);

    /*//////////////////////////////////////////////////////////////
                       LOAN AND PRICING ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @dev The loan is not in a status that allows this action.
    error BadStatus(LoanTypes.LoanStatus status);
    /// @dev The loan owes nothing.
    error NothingToRepay();
    /// @dev The guard is paused, its price is stale while the market is trading, or the collateral is worth zero.
    error OracleUnusable();
    /// @dev The sequencer came back online too recently and its grace period is still running.
    error SequencerGrace();

    /*//////////////////////////////////////////////////////////////
                        BORROWER AND LENDER CALLS
    //////////////////////////////////////////////////////////////*/

    /// @notice Funds a borrow request from one or more signed lend offers, all in one transaction.
    /// @dev If the borrower is the caller, `borrowerSignature` is not looked at. Any other caller must hold the
    ///      RELAYER role and present a borrower signature over the request that verifies. Offers are used in the
    ///      order supplied and must add up to exactly `request.principal`. Collateral always comes from the
    ///      borrower's wallet, so the borrower must have approved the hub even for a relayed request.
    /// @param request Borrow request being funded; its digest is used up by this call.
    /// @param borrowerSignature The borrower's EIP-712 signature on the request, only checked when relayed.
    /// @param offers Lend offers to draw on, in the order they should be used.
    /// @param signatures Signatures for `offers`, index for index.
    /// @return loanId Identifier of the new loan.
    function originate(
        LoanTypes.BorrowRequest calldata request,
        bytes calldata borrowerSignature,
        LoanTypes.LendOffer[] calldata offers,
        bytes[] calldata signatures
    ) external returns (uint256 loanId);
    /// @notice Makes a payment on a loan. Any account may pay. Interest is covered before principal, and a payment
    ///         that clears the debt closes the loan and returns the collateral to the borrower.
    /// @dev Cannot be paused. Allowed while the loan is Active, grace period included, and while it is Defaulted
    ///      after a failed rollover. Refused once the liquidation auction has taken the loan.
    /// @param amount Loan token being offered. Any excess over the full debt stays with the payer.
    function repay(uint256 loanId, uint256 amount) external;
    /// @notice Tops up a loan's collateral. Any account may do so, whenever a payment would be accepted and also
    ///         during a rollover.
    function addCollateral(uint256 loanId, uint256 amount) external;
    /// @notice Uses up a signed request so relayers can no longer submit it. Callable only by the request's
    ///         borrower.
    function cancelRequest(LoanTypes.BorrowRequest calldata request) external;

    /*//////////////////////////////////////////////////////////////
                               READS
    //////////////////////////////////////////////////////////////*/

    /// @notice The complete loan record, with the ids of its live slices.
    function getLoan(uint256 loanId) external view returns (LoanTypes.Loan memory);
    /// @notice The complete slice record. Every field is zero once a slice has been retired.
    function getSlice(uint256 sliceId) external view returns (LoanTypes.Slice memory);
    /// @notice Principal and interest still owed across all slices, with interest brought up to this block.
    /// @return principal Total principal of the slices.
    /// @return interest Total interest due, each slice floored at its minimum interest.
    function debtOf(uint256 loanId) external view returns (uint256 principal, uint256 interest);
    /// @notice Collateral value multiplied by the tier's liquidation LTV and divided by the debt. A loan under
    ///         1e18 is open to liquidation. With no debt the result is `type(uint256).max`.
    /// @return hfWad The health factor in 18-decimal fixed point.
    function healthFactor(uint256 loanId) external view returns (uint256 hfWad);
    /// @notice Debt as a share of collateral value right now, in basis points, or `type(uint256).max` if the
    ///         collateral is worth nothing.
    function ltvBps(uint256 loanId) external view returns (uint256);
    /// @notice Number of loans created, including any produced by a liquidation split. The first id is 1.
    function loanCount() external view returns (uint256);
    /// @notice True once a request digest has funded a loan or been cancelled.
    function requestUsed(bytes32 requestHash) external view returns (bool);

    /*//////////////////////////////////////////////////////////////
                         SHARED AUCTION HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @notice Checks a lend offer and records `fill` against it, returning the offer's EIP-712 digest.
    /// @dev The rollover market uses this when it accepts an offer. It moves no tokens and mints nothing. It
    ///      reverts for an expired, cancelled or badly signed offer, or if the fill would go past `principalMax`.
    function consumeOffer(LoanTypes.LendOffer calldata offer, bytes calldata signature, uint256 fill)
        external
        returns (bytes32 offerHash);
    /// @notice Gives `amount` of capacity back to the offer with the given digest after a recorded fill was
    ///         reversed. The rollover market calls this while refunding acceptances.
    function releaseOffer(bytes32 offerHash, uint256 amount) external;
    /// @notice Sends `amount` of `lender`'s capital parked with the reserve adapter to `to`.
    function pullFromIdle(address lender, uint256 amount, address to) external;

    /*//////////////////////////////////////////////////////////////
                          LIQUIDATION HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @notice Puts an Active or Defaulted loan into Liquidating, cancelling any rollover that is under way.
    function beginLiquidation(uint256 loanId) external;
    /// @notice Lifts `keepSliceIds` out of a Liquidating loan, along with collateral proportional to their
    ///         principal, and places them on a new Active loan with the same terms.
    /// @return newLoanId Identifier of the loan now holding those slices.
    function splitForLiquidation(uint256 loanId, uint256[] calldata keepSliceIds) external returns (uint256 newLoanId);
    /// @notice Settles one slice by paying its claim in collateral at `price`, then retires it.
    /// @param price Quote from the guard, in loan-token base units for one whole collateral token.
    function settleInKind(uint256 loanId, uint256 sliceId, uint256 price) external;
    /// @notice Pays out `amount` of escrowed collateral from a Liquidating loan to the recipient `to`. Choosing
    ///         and vetting that recipient is up to the auction.
    function transferCollateral(uint256 loanId, address to, uint256 amount) external;
    /// @notice Pushes `proceeds` through the penalty waterfall, hands any unsold collateral back to the borrower,
    ///         and closes the loan as Settled.
    /// @param proceeds Loan token that the auction has already sent to the hub.
    /// @param keeper Account that receives the keeper's portion of the penalty.
    function finalizeLiquidation(uint256 loanId, uint256 proceeds, address keeper) external;

    /*//////////////////////////////////////////////////////////////
                           ROLLOVER HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @notice Puts an Active loan into Refinancing. Requires `caller` to be the borrower and the loan to be
    ///         short of maturity.
    function beginRefinance(uint256 loanId, address caller) external;
    /// @notice Puts a Refinancing loan back to Active without altering its terms.
    function cancelRefinance(uint256 loanId) external;
    /// @notice Pays off the current lenders using funds the auction has already sent to the hub, collects the
    ///         rollover fee, and starts the loan again over `newTerm` with `slices` as its lenders.
    /// @dev The principal in `slices` must total the outgoing debt plus `feeAmount`. The call reverts if the
    ///      loan would not be healthy at the new principal.
    /// @return sliceIds Ids of the slices created for the new lenders, matching the order of `slices`.
    function clearRefinance(uint256 loanId, LoanTypes.SliceInput[] calldata slices, uint32 newTerm, uint256 feeAmount)
        external
        returns (uint256[] memory sliceIds);
    /// @notice Moves an Active or Refinancing loan to Defaulted. Payments remain possible.
    function markDefaulted(uint256 loanId) external;

    /*//////////////////////////////////////////////////////////////
                          SLICE NOTE HOOK
    //////////////////////////////////////////////////////////////*/

    /// @notice Called by the slice note when a note passes between holders, so that `sliceId` pays `to` from now
    ///         on.
    function onSliceTransfer(uint256 sliceId, address to) external;
}
