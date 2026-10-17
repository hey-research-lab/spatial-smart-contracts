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

    function test_renewManyExtendsEachAccount() public {
        address[] memory accounts = new address[](2);
        accounts[0] = lender1;
        accounts[1] = lender2;
        uint64 newExpiry = uint64(block.timestamp + 730 days);

        vm.prank(issuer);
        credentials.renewMany(accounts, Permissions.LENDER_PROFESSIONAL, newExpiry);

        assertEq(credentials.attestation(lender1, Permissions.LENDER_PROFESSIONAL).expiry, newExpiry);
        assertEq(credentials.attestation(lender2, Permissions.LENDER_PROFESSIONAL).expiry, newExpiry);
        assertEq(
            credentials.attestation(lender3, Permissions.LENDER_PROFESSIONAL).expiry,
            uint64(block.timestamp + 365 days),
            "a lender left out of the batch keeps its old expiry"
        );
    }

    function test_renewManyRevertsIfAnyAccountHasNoRecord() public {
        address[] memory accounts = new address[](2);
        accounts[0] = lender1;
        accounts[1] = makeAddr("nobody");
        uint64 before = credentials.attestation(lender1, Permissions.LENDER_PROFESSIONAL).expiry;

        vm.prank(issuer);
        vm.expectRevert(CredentialRegistry.NoActiveRecord.selector);
        credentials.renewMany(accounts, Permissions.LENDER_PROFESSIONAL, uint64(block.timestamp + 730 days));
        assertEq(credentials.attestation(lender1, Permissions.LENDER_PROFESSIONAL).expiry, before);
    }
}
