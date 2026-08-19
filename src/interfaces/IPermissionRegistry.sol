// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IAccessAdapter
/// @notice Pluggable credential source that the permission registry defers to for every role check. It can wrap
///         EAS, ONCHAINID, Chainlink ACE, the credential registry in this repository, or any similar system.
interface IAccessAdapter {
    /// @notice Returns true if `account` is presently cleared for `role`.
    function isEligible(address account, bytes32 role) external view returns (bool);
    /// @notice Uid and expiry of the credential that supports `account` holding `role`, or both zero if no
    ///         such credential exists.
    function attestationOf(address account, bytes32 role) external view returns (bytes32 uid, uint64 expiry);
}

/// @title IPermissionRegistry
/// @notice Access gate checked when a loan is originated, when lenders supply funds, when a rollover is filled,
///         and whenever a slice note or a portion of collateral changes hands.
interface IPermissionRegistry {
    /// @dev `account` is not cleared for `role`.
    error NotEligible(address account, bytes32 role);
    /// @dev `account` qualifies under neither lender role, professional or retail.
    error NotLender(address account);

    /// @notice Returns true if `account` is presently cleared for `role`.
    function isEligible(address account, bytes32 role) external view returns (bool);
    /// @notice Returns true if `account` qualifies under at least one of the two lender roles.
    function isLender(address account) external view returns (bool);
    /// @notice Passes silently when `account` has `role` and reverts with `NotEligible` when it does not.
    function requireRole(address account, bytes32 role) external view;
    /// @notice Passes silently for a qualified lender and reverts with `NotLender` for anyone else.
    function requireLender(address account) external view;
    /// @notice Uid and expiry of the credential that supports `account` holding `role`, or both zero if no
    ///         such credential exists.
    function attestationOf(address account, bytes32 role) external view returns (bytes32 uid, uint64 expiry);
}
