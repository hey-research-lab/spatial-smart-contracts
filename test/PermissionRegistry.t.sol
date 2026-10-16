// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {Permissions} from "../src/libraries/LoanTypes.sol";

/// @notice Tests for the permission registry's batch role lookup.
contract PermissionRegistryTest is BaseTest {
    function test_rolesOfReportsEachRoleInOrder() public view {
        bytes32[] memory roles = new bytes32[](3);
        roles[0] = Permissions.BORROWER;
        roles[1] = Permissions.LENDER_PROFESSIONAL;
        roles[2] = Permissions.LIQUIDATOR;

        bool[] memory borrowerRoles = permissions.rolesOf(borrower, roles);
        assertEq(borrowerRoles.length, 3);
        assertTrue(borrowerRoles[0]);
        assertFalse(borrowerRoles[1]);
        assertFalse(borrowerRoles[2]);

        bool[] memory lenderRoles = permissions.rolesOf(lender1, roles);
        assertFalse(lenderRoles[0]);
        assertTrue(lenderRoles[1]);
        assertFalse(lenderRoles[2]);
    }

    function test_rolesOfFollowsRevocation() public {
        bytes32[] memory roles = new bytes32[](1);
        roles[0] = Permissions.LIQUIDATOR;
        assertTrue(permissions.rolesOf(liquidator, roles)[0]);

        vm.prank(issuer);
        credentials.revoke(liquidator, Permissions.LIQUIDATOR);
        assertFalse(permissions.rolesOf(liquidator, roles)[0]);
    }
}
