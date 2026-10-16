// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {CredentialRegistry} from "../src/adapters/CredentialRegistry.sol";
import {Permissions} from "../src/libraries/LoanTypes.sol";

/// @notice Tests for renewing credentials in the credential registry.
contract CredentialRegistryTest is BaseTest {
    function test_renewKeepsTheUidAndExtendsExpiry() public {
        CredentialRegistry.Attestation memory before = credentials.attestation(borrower, Permissions.BORROWER);
        uint64 newExpiry = uint64(block.timestamp + 730 days);

        vm.prank(issuer);
        credentials.renew(borrower, Permissions.BORROWER, newExpiry);

        CredentialRegistry.Attestation memory after_ = credentials.attestation(borrower, Permissions.BORROWER);
        assertEq(after_.uid, before.uid);
        assertEq(after_.expiry, newExpiry);
        assertEq(after_.jurisdictionClass, before.jurisdictionClass);

        vm.warp(block.timestamp + 400 days);
        assertTrue(permissions.isEligible(borrower, Permissions.BORROWER));
    }

    function test_renewBringsBackALapsedCredential() public {
        vm.warp(block.timestamp + 366 days);
        assertFalse(permissions.isEligible(borrower, Permissions.BORROWER));

        vm.prank(issuer);
        credentials.renew(borrower, Permissions.BORROWER, uint64(block.timestamp + 30 days));
        assertTrue(permissions.isEligible(borrower, Permissions.BORROWER));
    }

    function test_renewRejectsRevokedMissingAndPastExpiry() public {
        vm.prank(issuer);
        vm.expectRevert(CredentialRegistry.NoActiveRecord.selector);
        credentials.renew(makeAddr("nobody"), Permissions.BORROWER, uint64(block.timestamp + 30 days));

        vm.prank(issuer);
        vm.expectRevert(CredentialRegistry.BadExpiry.selector);
        credentials.renew(borrower, Permissions.BORROWER, uint64(block.timestamp));

        vm.prank(issuer);
        credentials.revoke(borrower, Permissions.BORROWER);
        vm.prank(issuer);
        vm.expectRevert(CredentialRegistry.NoActiveRecord.selector);
        credentials.renew(borrower, Permissions.BORROWER, uint64(block.timestamp + 30 days));
    }

    function test_onlyIssuersCanRenew() public {
        vm.prank(borrower);
        vm.expectRevert(CredentialRegistry.NotIssuer.selector);
        credentials.renew(borrower, Permissions.BORROWER, uint64(block.timestamp + 730 days));
    }
}
