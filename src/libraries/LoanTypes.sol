// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title LoanTypes
/// @notice Shared vocabulary for the Spatial contracts. It holds the enums for book side, market session and
///         loan state, the bit flags a lender can set on an offer, the numeric units, and the structs used for
///         signed messages, loans and slices.
library LoanTypes {
    /*//////////////////////////////////////////////////////////////
                                ENUMS
    //////////////////////////////////////////////////////////////*/

    /// @notice Marks a signed message as coming from a lender or a borrower. Only `Lend` messages can be filled
    ///         by the hub; a `Borrow` message is refused.
    enum Side {
        Lend,
        Borrow
    }

    /// @notice The guard's view of where the underlying equity's market stands for a given collateral token.
    enum Session {
        Regular,
        Extended,
        Closed
    }

    /// @notice Where a loan sits in its life.
    /// @dev A loan stays `Active` through its term, through the grace period that follows maturity, and for as
    ///      long afterwards as no collateral auction has started. While a rollover auction runs the loan is
    ///      `Refinancing`. A loan paid off in full ends as `Repaid`, while one closed by an auction ends as
    ///      `Settled`. `Defaulted` loans can still be paid down, and they may be sent to auction regardless of
    ///      their health factor.
    enum LoanStatus {
        None,
        Active,
        Refinancing,
        Liquidating,
        Repaid,
        Settled,
        Defaulted
    }

    /*//////////////////////////////////////////////////////////////
                         OFFER FLAG BITS
    //////////////////////////////////////////////////////////////*/

    /// @dev On liquidation this lender takes collateral, priced by the guard, rather than a cut of the auction
    ///      proceeds. What they receive is limited to their slice's principal-weighted portion of the escrow.
    uint8 internal constant FLAG_SELF_LIQUIDATE = 1 << 0;
    /// @dev This lender's slice must not be sold while the stock market is shut. A loan in which every slice
    ///      sets this bit cannot go to auction at all during a closed session.
    uint8 internal constant FLAG_NO_CLOSED_MARKET_LIQUIDATION = 1 << 1;
    /// @dev Idle loan token for this lender is held in the vault that the reserve adapter fronts. The hub pulls
    ///      out just the amount needed whenever a loan is funded or a rollover acceptance is taken.
    uint8 internal constant FLAG_PARK_IDLE = 1 << 2;

    /*//////////////////////////////////////////////////////////////
                                 UNITS
    //////////////////////////////////////////////////////////////*/

    /// @dev Ten thousand basis points make a whole. Rates, shares and ratios across the protocol use this scale.
    uint256 internal constant BPS = 10_000;
    /// @dev The value 1.0 in 18-decimal fixed point, the scale health factors are reported in.
    uint256 internal constant WAD = 1e18;
    /// @dev Length of a year for accrual. Rates are annual and interest builds up second by second against it.
    uint256 internal constant YEAR = 365 days;

    /*//////////////////////////////////////////////////////////////
                            SIGNED MESSAGES
    //////////////////////////////////////////////////////////////*/

    /// @notice What a lender signs, under the Spatial EIP-712 domain, to offer credit either to anyone or to one
    ///         specific request. Producing or withdrawing an offer needs no transaction; tokens only move once the
    ///         hub draws on it and creates a slice.
    /// @dev A fill smaller than `principalMin` is refused, except when it uses up the last of the offer. The
    ///      offer funds loans up to a loan-to-value of `maxLtvBps`. `nonce` picks a bit in the maker's
    ///      cancellation bitmap; filling the offer leaves that bit untouched.
    struct LendOffer {
        address maker;
        Side side;
        /// @dev Either one specific collateral token, or `address(uint160(tier))` as a tier wildcard so that any
        ///      collateral in that risk tier qualifies.
        address collateralToken;
        address loanToken;
        uint256 principalMin;
        uint256 principalMax;
        uint16 aprBps;
        uint16 maxLtvBps;
        uint32 termSeconds;
        uint40 expiry;
        uint256 nonce;
        bytes32 salt;
        /// @dev Left as zero, the offer is open to any request. Otherwise it holds either the digest of the single
        ///      borrow request it is meant for, or `QuoteHash.rolloverKey` for the single loan whose rollover it
        ///      may join.
        bytes32 requestId;
        uint8 flags;
    }

    /// @notice What a borrower asks for: the collateral to post, the principal wanted, a ceiling on the APR, the
    ///         term, and the last moment the request may be filled. When a relayer or anyone else submits it on
    ///         the borrower's behalf, an EIP-712 signature from the borrower must accompany it.
    struct BorrowRequest {
        address borrower;
        address collateralToken;
        address loanToken;
        uint256 collateralAmount;
        uint256 principal;
        uint16 maxAprBps;
        uint32 termSeconds;
        uint40 fillDeadline;
        bytes32 salt;
    }

    /*//////////////////////////////////////////////////////////////
                          LEDGER RECORDS
    //////////////////////////////////////////////////////////////*/

    /// @notice A single lender's position in a loan, tracking its principal, rate and interest. The slice note
    ///         carrying the same id proves who owns it, and `lender` is updated whenever that note is transferred.
    /// @dev `minInterest` is the floor owed for the minimum interest period, payable even if the loan is cleared
    ///      early. `accruedInterest` holds straight-line interest counted up to `lastAccrual`, and `interestPaid`
    ///      tracks how much of it has reached the lender.
    struct Slice {
        uint256 loanId;
        address lender;
        uint128 principal;
        uint128 minInterest;
        uint128 accruedInterest;
        uint128 interestPaid;
        uint40 lastAccrual;
        uint16 aprBps;
        uint8 flags;
    }

    /// @notice The borrower-facing record of a loan: a single pot of escrowed collateral that secures however many
    ///         slices funded it.
    /// @dev `principal` always matches the total principal of the slices still listed. Entries leave `sliceIds`
    ///      when a slice is settled in collateral or moved to another loan by a liquidation split.
    struct Loan {
        address borrower;
        address collateralToken;
        address loanToken;
        uint128 collateralAmount;
        uint128 principal;
        uint40 startedAt;
        uint40 maturity;
        uint32 termSeconds;
        LoanStatus status;
        uint256[] sliceIds;
    }

    /// @notice Everything required to create a slice. The hub assembles these during origination, and the
    ///         rollover market assembles them from its accepted offers when a rollover completes.
    struct SliceInput {
        address lender;
        uint256 principal;
        uint16 aprBps;
        uint8 flags;
    }
}

/// @title Permissions
/// @notice Role identifiers looked up in the permission registry. Each of borrowing, lending, bidding in a
///         collateral auction and submitting a request for someone else is gated by its own role.
library Permissions {
    bytes32 internal constant BORROWER = keccak256("spatial.role.BORROWER");
    bytes32 internal constant LENDER_PROFESSIONAL = keccak256("spatial.role.LENDER_PROFESSIONAL");
    bytes32 internal constant LENDER_RETAIL = keccak256("spatial.role.LENDER_RETAIL");
    bytes32 internal constant LIQUIDATOR = keccak256("spatial.role.LIQUIDATOR");
    bytes32 internal constant RELAYER = keccak256("spatial.role.RELAYER");
}
