// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRiskConfig} from "./interfaces/IRiskConfig.sol";

/// @title FeeVault
/// @notice Collection point for everything the protocol earns: origination fees, its share of interest,
///         rollover fees and its portion of liquidation auction penalties. The hub pays in with plain token
///         transfers, so the fee vault needs no deposit hook. Withdrawals are reserved for the owner of the risk
///         config, initially a multisig and eventually a governance module.
contract FeeVault {
    using SafeERC20 for IERC20;

    IRiskConfig public immutable riskConfig;

    event Withdrawn(address indexed token, address indexed to, uint256 amount);

    error NotGovernance();
    error ZeroRecipient();
    error LengthMismatch();

    constructor(IRiskConfig riskConfig_) {
        riskConfig = riskConfig_;
    }

    /// @notice Transfer `amount` of `token` out to `to`. Works for any ERC-20 held here, including tokens that
    ///         arrived by accident. A zero recipient is rejected because many tokens would simply destroy the
    ///         funds. Supplying `type(uint256).max` as the amount sends the entire balance, which is handy for
    ///         governance proposals drafted ahead of execution, when the final fee total is not yet known.
    function withdraw(IERC20 token, address to, uint256 amount) external {
        _onlyGovernance();
        if (to == address(0)) revert ZeroRecipient();
        _payout(token, to, amount);
    }

    /// @notice Batch version of `withdraw` that sweeps several tokens to one recipient in a single call, so a
    ///         treasury proposal does not need one action per fee token. `tokens` and `amounts` are paired by
    ///         index, and `type(uint256).max` again means the full balance of that token.
    function withdrawMany(IERC20[] calldata tokens, address to, uint256[] calldata amounts) external {
        _onlyGovernance();
        if (to == address(0)) revert ZeroRecipient();
        uint256 count = tokens.length;
        if (amounts.length != count) revert LengthMismatch();
        for (uint256 i; i < count; ++i) {
            _payout(tokens[i], to, amounts[i]);
        }
    }

    /// @notice Balance of `token` currently held here, for dashboards and proposal tooling.
    function balanceOf(IERC20 token) external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    function _onlyGovernance() private view {
        if (msg.sender != riskConfig.owner()) revert NotGovernance();
    }

    /// @dev A payout that works out to zero, typically a full-balance sweep of a token with nothing collected
    ///      yet, is skipped without a transfer or an event. That keeps a batch from failing on tokens that
    ///      reject zero transfers, and keeps zero-value `Withdrawn` events out of the treasury history.
    function _payout(IERC20 token, address to, uint256 amount) private {
        uint256 payout = amount == type(uint256).max ? token.balanceOf(address(this)) : amount;
        if (payout == 0) return;
        token.safeTransfer(to, payout);
        emit Withdrawn(address(token), to, payout);
    }
}
