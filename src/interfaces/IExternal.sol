// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Third-party surfaces the protocol talks to. Function names and signatures follow the upstream contracts
// exactly and must stay that way.

/// @notice Read side of a Chainlink aggregator, trimmed to the two calls the protocol makes. Both the collateral
///         price feeds and the L2 sequencer uptime feed speak this interface.
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice ERC-8056 multiplier hook, in the form Robinhood Stock Tokens expose it.
interface IERC8056 {
    /// @return How many underlying shares one token represents, as an 18-decimal fixed-point number. It moves
    ///         when a split happens or a dividend is reinvested.
    function uiMultiplier() external view returns (uint256);
}

/// @notice Reports whether pricing for a token should be treated as halted, typically while a corporate action
///         is being processed. The token can implement this itself, or a separate wrapper around a feed can.
interface IOraclePauseSource {
    function oraclePaused() external view returns (bool);
}

/// @notice Reports which trading session the underlying share is in, using the numeric codes found in Chainlink
///         Data Streams RWA reports.
interface IMarketStatusSource {
    /// @return status The session code: 1 means regular hours, 2 means extended hours and 5 means closed.
    function marketStatus() external view returns (uint8 status);
}

/// @notice Checks a signed Chainlink Data Streams report on chain and hands back the price inside it.
interface IStreamAdapter {
    /// @param collateralToken Collateral token whose stream produced the report.
    /// @param report Raw signed payload as published for that stream.
    /// @return price Price from the report, using the decimal count of the token's aggregator.
    /// @return observedAt Timestamp at which the report says the price was observed.
    function verify(address collateralToken, bytes calldata report) external returns (uint256 price, uint256 observedAt);
}
