// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    AggregatorV3Interface,
    IERC8056,
    IOraclePauseSource,
    IMarketStatusSource,
    IStreamAdapter
} from "../interfaces/IExternal.sol";

// Stand-ins used by the test suite and by the testnet deployment scripts. None of them has any access control:
// any account can mint itself tokens or move a price, so they must never be deployed to mainnet.

/// @notice Freely mintable ERC-20 whose decimal count is fixed at construction.
contract MockERC20 is ERC20 {
    uint8 internal immutable _customDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _customDecimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public view override returns (uint8) {
        return _customDecimals;
    }
}

/// @notice Pretend Robinhood Stock Token. It is an 18-decimal ERC-20 that also answers as its own ERC-8056
///         multiplier, pause source and market-status source, and every one of those values is open for anyone
///         to change.
contract MockStockToken is ERC20, IERC8056, IOraclePauseSource, IMarketStatusSource {
    uint256 public multiplier = 1e18;
    bool public paused;
    uint8 public status = 1; // starts in regular hours (Chainlink codes: 1 regular, 2 extended, 5 closed)

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    // Test controls

    function setMultiplier(uint256 m) external {
        multiplier = m;
    }

    function setOraclePaused(bool p) external {
        paused = p;
    }

    function setMarketStatus(uint8 s) external {
        status = s;
    }

    // Oracle-facing reads

    function uiMultiplier() external view override returns (uint256) {
        return multiplier;
    }

    function oraclePaused() external view override returns (bool) {
        return paused;
    }

    function marketStatus() external view override returns (uint8) {
        return status;
    }
}

/// @notice Aggregator double with a writable answer. `set` advances the round and dates the answer to the
///         current block, while `setWithTimestamps` takes explicit `startedAt` and `updatedAt` values so a test
///         can simulate an old answer or a recent sequencer restart.
contract MockAggregatorV3 is AggregatorV3Interface {
    uint8 public immutable dec;
    int256 public answer;
    uint256 public updatedAt;
    uint256 public startedAt;
    uint80 public round;

    constructor(uint8 decimals_, int256 initial) {
        dec = decimals_;
        answer = initial;
        updatedAt = block.timestamp;
        startedAt = block.timestamp;
        round = 1;
    }

    function set(int256 a) external {
        answer = a;
        updatedAt = block.timestamp;
        round++;
    }

    function setWithTimestamps(int256 a, uint256 started, uint256 updated) external {
        answer = a;
        startedAt = started;
        updatedAt = updated;
        round++;
    }

    function decimals() external view override returns (uint8) {
        return dec;
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (round, answer, startedAt, updatedAt, round);
    }
}

/// @notice Bare ERC-4626 vault over a single asset, for networks where no Morpho vault is available.
contract MockVault4626 is ERC4626 {
    constructor(IERC20 asset_) ERC20("Mock USDG Vault", "mvUSDG") ERC4626(asset_) {}
}

/// @notice Stream adapter that skips verification entirely and echoes back whatever price was last stored.
///         `set` timestamps the price with the current block; `setWithTimestamp` accepts any time the test needs.
contract MockStreamAdapter is IStreamAdapter {
    uint256 public price;
    uint256 public reportedAt;

    function set(uint256 p) external {
        price = p;
        reportedAt = block.timestamp;
    }

    function setWithTimestamp(uint256 p, uint256 ts) external {
        price = p;
        reportedAt = ts;
    }

    function verify(address, bytes calldata) external view override returns (uint256, uint256) {
        return (price, reportedAt);
    }
}
