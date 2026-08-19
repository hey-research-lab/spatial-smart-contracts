// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IRiskConfig
/// @notice Read surface of the risk config, through which other contracts look up governance settings.
interface IRiskConfig {
    /// @notice Risk bracket that collateral tokens are assigned to. All ratios are basis points of the
    ///         collateral's value.
    struct TierConfig {
        /// @dev Ceiling on LTV when a loan is opened.
        uint16 maxLtvBps;
        /// @dev LTV beyond which a loan can be liquidated.
        uint16 liqLtvBps;
        /// @dev Reduction applied to both ceilings when the market is shut or the feed answer is stale.
        uint16 closedHaircutBps;
        bool enabled;
    }

    /// @notice Settings for an individual collateral token.
    struct TokenConfig {
        /// @dev The token's tier, which has to be enabled for the token itself to be enabled.
        uint8 tier;
        /// @dev Maximum total principal, in loan-token units, that may be outstanding against this token.
        uint128 exposureCap;
        bool enabled;
    }

    /// @notice Loan lifecycle settings that apply protocol-wide.
    struct LoanParams {
        /// @dev Minimum span of interest, in seconds, charged to a borrower even if they repay straight away.
        uint32 minInterestPeriod;
        /// @dev Seconds past maturity in which a repayment is still taken before the loan can go to auction.
        uint32 graceWindow;
        /// @dev Seconds after the L2 sequencer comes back up during which new loans and liquidations remain
        ///      blocked.
        uint32 sequencerGrace;
        /// @dev Cap on the number of slices in a single loan. Repaying and liquidating both iterate over every
        ///      slice, so without a cap a large syndicate could make those transactions too expensive to fit in
        ///      a block.
        uint16 maxSlicesPerLoan;
    }

    /// @notice Settings for the liquidation auction, with prices measured against the guard price when the
    ///         auction opens.
    struct AuctionParams {
        /// @dev Mark-up on the guard price where the falling price begins.
        uint16 startPremiumBps;
        /// @dev Lowest the price may fall, as a share of the guard price, during trading hours.
        uint16 floorBpsRegular;
        /// @dev The equivalent floor when the market is shut. A higher value restricts discounts outside hours.
        uint16 floorBpsClosed;
        /// @dev Time in seconds the price takes to descend from start to floor.
        uint32 duration;
        /// @dev Penalty added to the debt when a loan is liquidated.
        uint16 penaltyBps;
        /// @dev Portion of the penalty awarded to the keeper.
        uint16 keeperShareBps;
        /// @dev Portion of what remains after the keeper is paid that goes to lenders. Anything left over belongs
        ///      to the protocol and is sent to the fee vault.
        uint16 lenderPenaltyShareBps;
    }

    /// @notice Settings for the rollover market's rate auction.
    struct RefinanceParams {
        /// @dev Spread over the loan's blended APR that sets the highest rate the auction can reach.
        uint16 capSpreadBps;
        /// @dev Time in seconds for the rate to rise from the blended APR to that ceiling.
        uint32 duration;
    }

    /// @notice Protocol fee rates.
    struct FeeParams {
        /// @dev Borrower-paid fee on principal, taken when the loan is originated.
        uint16 originationBps;
        /// @dev Portion of interest payments sent to the fee vault and deducted from what lenders receive.
        uint16 interestShareBps;
        /// @dev Borrower-paid fee taken when a rollover is filled.
        uint16 refinanceBps;
        /// @dev Portion of idle vault yield earmarked for the protocol. Kept for the reserve adapter's future use;
        ///      nothing reads it at present.
        uint16 idleYieldShareBps;
    }

    // Roles

    /// @notice Governance account that controls the timelock and administers the protocol's other contracts.
    function owner() external view returns (address);
    /// @notice Account allowed to halt new loans and liquidations immediately, without waiting on the timelock.
    function guardian() external view returns (address);

    // Halt flags

    function newLoansPaused() external view returns (bool);
    function liquidationsPaused() external view returns (bool);

    // Collateral and loan terms

    function tierConfig(uint8 tier) external view returns (TierConfig memory);
    function tokenConfig(address token) external view returns (TokenConfig memory);
    function loanTokenEnabled(address token) external view returns (bool);
    function termAllowed(uint32 termSeconds) external view returns (bool);

    // Parameter sets

    function loanParams() external view returns (LoanParams memory);
    function auctionParams() external view returns (AuctionParams memory);
    function refinanceParams() external view returns (RefinanceParams memory);
    function feeParams() external view returns (FeeParams memory);

    // Allow-lists and integrations

    function vaultWhitelisted(address vault) external view returns (bool);
    function attestationIssuer(address issuer) external view returns (bool);
    /// @notice Adapter that the permission registry currently hands eligibility checks to.
    function eligibilityAdapter() external view returns (address);
}
