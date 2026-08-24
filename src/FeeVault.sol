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

    constructor(IRiskConfig riskConfig_) {
        riskConfig = riskConfig_;
    }

    /// @notice Transfer `amount` of `token` out to `to`. Works for any ERC-20 held here, including tokens that
    ///         arrived by accident. A zero recipient is rejected because many tokens would simply destroy the
    ///         funds. Supplying `type(uint256).max` as the amount sends the entire balance, which is handy for
    ///         governance proposals drafted ahead of execution, when the final fee total is not yet known.
    function withdraw(IERC20 token, address to, uint256 amount) external {
        if (msg.sender != riskConfig.owner()) revert NotGovernance();
        if (to == address(0)) revert ZeroRecipient();
        uint256 payout = amount == type(uint256).max ? token.balanceOf(address(this)) : amount;
        token.safeTransfer(to, payout);
        emit Withdrawn(address(token), to, payout);
    }
}
