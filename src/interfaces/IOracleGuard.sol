// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LoanTypes} from "../libraries/LoanTypes.sol";

/// @title IOracleGuard
/// @notice Collateral valuation for the protocol. Nothing else in the system is allowed to price collateral.
interface IOracleGuard {
    /// @notice A price together with the context a caller needs to judge whether to trust it.
    struct Quote {
        /// @dev Value of one whole collateral token, expressed in base units of the loan token.
        uint256 price;
        /// @dev Timestamp the feed attached to its answer.
        uint64 updatedAt;
        /// @dev Which trading session the underlying share was in when the quote was taken.
        LoanTypes.Session session;
        /// @dev Set when pricing is halted for any reason: a tripped move cap, a manual pause by governance, or
        ///      the token's own pause source.
        bool paused;
        /// @dev Set when the answer is older than the current session allows.
        bool stale;
        /// @dev ERC-8056 `uiMultiplier()` of the token, or 1e18 if it reports none. Carried for display and never
        ///      applied to `price`.
        uint256 multiplier;
        /// @dev Set while the L2 sequencer is down or is still inside the grace period after coming back.
        bool sequencerGrace;
    }

    error FeedNotConfigured(address token);
    /// @dev The feed answered with zero or a negative number, or with a timestamp that cannot be used.
    error PriceInvalid(address token);
    /// @dev Available to callers that want to reject a halted market. The guard itself never throws it and
    ///      signals a halt through `Quote.paused` instead.
    error MarketPaused(address token);

    // Pricing

    /// @notice Price a collateral token without writing anything. A stale or halted market is reported through
    ///         the returned flags, not by reverting.
    function quote(address collateralToken) external view returns (Quote memory);
    /// @notice Take a quote and record it as the new move-cap checkpoint. When the price has jumped by more than
    ///         the cap relative to a sufficiently recent checkpoint, the market is halted and the quote is
    ///         returned with its pause flag set. The hub calls this when a loan is originated, and the
    ///         liquidation auction calls it when an auction opens or is restarted.
    function refresh(address collateralToken) external returns (Quote memory);
    /// @notice Pass a Data Streams report to the token's adapter for verification and return the price it holds,
    ///         converted to loan-token units. Reverts if the token has no stream configured or if the stream
    ///         price sits too far from the feed price.
    function verifyStreamReport(address collateralToken, bytes calldata report) external returns (uint256 price);

    // Configuration reads

    /// @notice The loan token in which a collateral token is priced, fixed when its feed was set up. Any loan
    ///         secured by that collateral must be denominated in this token, since every guard price is given in
    ///         its base units and mixing currencies would make the LTV meaningless.
    function quoteToken(address collateralToken) external view returns (address);
    /// @notice The collateral token's decimal count, as captured when its feed was set up.
    function collateralDecimals(address collateralToken) external view returns (uint8);
    /// @notice Whether the token has a Data Streams adapter attached.
    function hasStream(address collateralToken) external view returns (bool);
}
