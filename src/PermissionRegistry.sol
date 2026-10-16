// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPermissionRegistry, IAccessAdapter} from "./interfaces/IPermissionRegistry.sol";
import {IRiskConfig} from "./interfaces/IRiskConfig.sol";
import {Permissions} from "./libraries/LoanTypes.sol";

/// @title PermissionRegistry
/// @notice Single entry point for access checks across the protocol: may a given address borrow, lend,
///         liquidate, relay or own a slice note? The permission registry holds no policy of its own. Each query is
///         passed straight through to whichever adapter the risk config points at, which lets governance swap
///         the credential source (EAS, ONCHAINID, Chainlink ACE, or the credential registry shipped here)
///         while every consumer keeps the same address. All reads are open to anyone.
contract PermissionRegistry is IPermissionRegistry {
    IRiskConfig public immutable riskConfig;

    error AdapterNotSet();

    constructor(IRiskConfig riskConfig_) {
        riskConfig = riskConfig_;
    }

    /*//////////////////////////////////////////////////////////////
                              ADAPTER LOOKUP
    //////////////////////////////////////////////////////////////*/

    /// @notice The adapter currently configured in the risk config, looked up fresh on every call so that a
    ///         governance switch is honoured from the very next query.
    /// @dev Reverts with `AdapterNotSet` if the risk config still points at the zero address.
    function adapter() public view returns (IAccessAdapter) {
        address current = riskConfig.eligibilityAdapter();
        if (current == address(0)) revert AdapterNotSet();
        return IAccessAdapter(current);
    }

    /*//////////////////////////////////////////////////////////////
                               ROLE QUERIES
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPermissionRegistry
    function isEligible(address account, bytes32 role) public view override returns (bool) {
        return adapter().isEligible(account, role);
    }

    /// @notice Convenience check for the borrower role, the counterpart of `isLender`. Equivalent to calling
    ///         `isEligible` with `Permissions.BORROWER`.
    function isBorrower(address account) external view returns (bool) {
        return isEligible(account, Permissions.BORROWER);
    }

    /// @notice Returns true if the account qualifies as a lender under either the professional or the retail
    ///         role.
    function isLender(address account) public view override returns (bool) {
        IAccessAdapter source = adapter();
        if (source.isEligible(account, Permissions.LENDER_PROFESSIONAL)) return true;
        return source.isEligible(account, Permissions.LENDER_RETAIL);
    }

    /// @notice Checks several roles for one account in a single call, resolving the adapter only once. Meant
    ///         for front ends that need to know everything an account is cleared for when it connects.
    /// @return eligible One flag per entry in `roles`, in the same order.
    function rolesOf(address account, bytes32[] calldata roles) external view returns (bool[] memory eligible) {
        IAccessAdapter source = adapter();
        uint256 count = roles.length;
        eligible = new bool[](count);
        for (uint256 i; i < count; ++i) {
            eligible[i] = source.isEligible(account, roles[i]);
        }
    }

    /// @inheritdoc IPermissionRegistry
    function attestationOf(address account, bytes32 role) external view override returns (bytes32 uid, uint64 expiry) {
        return adapter().attestationOf(account, role);
    }

    /*//////////////////////////////////////////////////////////////
                               ENFORCEMENT
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPermissionRegistry
    function requireRole(address account, bytes32 role) external view override {
        require(isEligible(account, role), NotEligible(account, role));
    }

    /// @inheritdoc IPermissionRegistry
    function requireLender(address account) external view override {
        require(isLender(account), NotLender(account));
    }
}
