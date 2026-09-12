// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {RiskConfig} from "../src/RiskConfig.sol";
import {IRiskConfig} from "../src/interfaces/IRiskConfig.sol";
import {Permissions} from "../src/libraries/LoanTypes.sol";
import {IPermissionRegistry} from "../src/interfaces/IPermissionRegistry.sol";
import {FeeVault} from "../src/FeeVault.sol";
import {SliceNote} from "../src/SliceNote.sol";
import {CredentialRegistry} from "../src/adapters/CredentialRegistry.sol";

/// @notice Tests for governance and its surroundings: the risk config's timelock after bootstrap, what the
///         guardian can and cannot do with pauses, parameter checks, credentials in the credential registry
///         (expiry, revocation, batch calls, issuer removal), slice note transfers limited to eligible holders,
///         withdrawals from the fee vault, and the hub's single wiring call.
contract RiskConfigTest is BaseTest {
    // =========================================================================
    // Timelocked batches
    // =========================================================================

    /// Once bootstrap is finished the owner can no longer call setters directly. A queued batch only runs after
    /// its one day delay has passed.
    function test_bootstrapLocksToTimelock() public {
        vm.prank(gov);
        riskConfig.finishBootstrap();

        vm.prank(gov);
        vm.expectRevert(RiskConfig.NotSelf.selector);
        riskConfig.setTermAllowed(60 days, true);

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(RiskConfig.setTermAllowed, (60 days, true));
        bytes32 salt = keccak256("term-60d");
        vm.prank(gov);
        riskConfig.schedule(calls, salt, keccak256("rationale: add 60 day term"));

        vm.prank(gov);
        vm.expectRevert(RiskConfig.OperationNotReady.selector);
        riskConfig.execute(calls, salt);

        vm.warp(block.timestamp + 1 days);
        vm.prank(gov);
        riskConfig.execute(calls, salt);
        assertTrue(riskConfig.termAllowed(60 days));
    }

    /// The point of the delay is to give users time to see a change coming and respond. If a queued batch never
    /// expired, its holder could keep it in reserve and trigger it at whatever moment suited them.
    function test_aQueuedBatchGoesStaleIfNobodyRunsIt() public {
        vm.prank(gov);
        riskConfig.finishBootstrap();

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(RiskConfig.setTermAllowed, (60 days, true));
        bytes32 salt = keccak256("term-60d-stale");
        vm.prank(gov);
        bytes32 id = riskConfig.schedule(calls, salt, keccak256("rationale: add 60 day term"));

        (uint64 eta,,,) = riskConfig.operations(id);
        vm.warp(uint256(eta) + riskConfig.GRACE_PERIOD() + 1);
        vm.prank(gov);
        vm.expectRevert(RiskConfig.OperationStale.selector);
        riskConfig.execute(calls, salt);

        // Waiting longer does not bring it back; this salt is spent.
        vm.warp(block.timestamp + 365 days);
        vm.prank(gov);
        vm.expectRevert(RiskConfig.OperationStale.selector);
        riskConfig.execute(calls, salt);

        // Queuing the identical calls under a new salt starts a new delay.
        bytes32 salt2 = keccak256("term-60d-again");
        vm.prank(gov);
        riskConfig.schedule(calls, salt2, keccak256("rationale: add 60 day term"));
        vm.warp(block.timestamp + 1 days);
        vm.prank(gov);
        riskConfig.execute(calls, salt2);
        assertTrue(riskConfig.termAllowed(60 days));
    }

    function test_aBatchRunsAtTheEdgeOfItsGracePeriod() public {
        vm.prank(gov);
        riskConfig.finishBootstrap();

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(RiskConfig.setTermAllowed, (60 days, true));
        bytes32 salt = keccak256("term-60d-edge");
        vm.prank(gov);
        bytes32 id = riskConfig.schedule(calls, salt, keccak256("rationale: add 60 day term"));

        (uint64 eta,,,) = riskConfig.operations(id);
        vm.warp(uint256(eta) + riskConfig.GRACE_PERIOD());
        vm.prank(gov);
        riskConfig.execute(calls, salt);
        assertTrue(riskConfig.termAllowed(60 days));
    }

    function test_anEmptyBatchCannotBeQueued() public {
        vm.prank(gov);
        vm.expectRevert(RiskConfig.EmptyBatch.selector);
        riskConfig.schedule(new bytes[](0), keccak256("empty"), bytes32(0));
    }

    function test_aBatchCannotBeCancelledTwice() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(RiskConfig.setTermAllowed, (60 days, true));
        vm.prank(gov);
        bytes32 id = riskConfig.schedule(calls, keccak256("cancel-twice"), bytes32(0));

        vm.prank(gov);
        riskConfig.cancel(id);
        vm.prank(gov);
        vm.expectRevert(RiskConfig.OperationAlreadyCancelled.selector);
        riskConfig.cancel(id);
    }

    function test_operationStateFollowsTheBatch() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(RiskConfig.setTermAllowed, (60 days, true));
        bytes32 salt = keccak256("state");
        bytes32 id = riskConfig.operationId(calls, salt);
        assertEq(uint8(riskConfig.operationState(id)), uint8(RiskConfig.OperationState.Unknown));

        vm.prank(gov);
        riskConfig.schedule(calls, salt, bytes32(0));
        assertEq(uint8(riskConfig.operationState(id)), uint8(RiskConfig.OperationState.Waiting));

        (uint64 eta,,,) = riskConfig.operations(id);
        vm.warp(eta);
        assertEq(uint8(riskConfig.operationState(id)), uint8(RiskConfig.OperationState.Ready));

        uint256 snapshot = vm.snapshotState();
        vm.warp(uint256(eta) + riskConfig.GRACE_PERIOD() + 1);
        assertEq(uint8(riskConfig.operationState(id)), uint8(RiskConfig.OperationState.Stale));
        vm.revertToState(snapshot);

        snapshot = vm.snapshotState();
        vm.prank(gov);
        riskConfig.cancel(id);
        assertEq(uint8(riskConfig.operationState(id)), uint8(RiskConfig.OperationState.Cancelled));
        vm.revertToState(snapshot);

        vm.prank(gov);
        riskConfig.execute(calls, salt);
        assertEq(uint8(riskConfig.operationState(id)), uint8(RiskConfig.OperationState.Executed));
    }

    // =========================================================================
    // Guardian and pauses
    // =========================================================================

    function test_guardianCanOnlyPause() public {
        vm.prank(guardian);
        riskConfig.setPaused(true, true);
        assertTrue(riskConfig.newLoansPaused());
        assertTrue(riskConfig.liquidationsPaused());
        vm.prank(guardian);
        vm.expectRevert(RiskConfig.NotOwner.selector);
        riskConfig.setTermAllowed(60 days, true);
    }

    /// The guardian key is built for speed, which also makes it the likeliest to be compromised. Letting it halt
    /// things without a delay risks nothing worse than lost activity. Resuming carries the opposite risk, so only
    /// the owner may do it.
    function test_guardianCannotLiftAPause() public {
        vm.prank(guardian);
        riskConfig.setPaused(true, true);

        vm.prank(guardian);
        vm.expectRevert(RiskConfig.GuardianCannotUnpause.selector);
        riskConfig.setPaused(false, true);

        vm.prank(guardian);
        vm.expectRevert(RiskConfig.GuardianCannotUnpause.selector);
        riskConfig.setPaused(true, false);

        // Setting flags that are already on counts as neither lifting a pause nor anything new.
        vm.prank(guardian);
        riskConfig.setPaused(true, true);
        assertTrue(riskConfig.newLoansPaused());

        vm.prank(gov);
        riskConfig.setPaused(false, false);
        assertFalse(riskConfig.newLoansPaused());
        assertFalse(riskConfig.liquidationsPaused());
    }

    function test_guardianMayRaiseOneFlagWhileTheOtherIsDown() public {
        vm.prank(guardian);
        riskConfig.setPaused(false, true);
        assertFalse(riskConfig.newLoansPaused());
        assertTrue(riskConfig.liquidationsPaused());

        vm.prank(guardian);
        riskConfig.setPaused(true, true);
        assertTrue(riskConfig.newLoansPaused());
    }

    /// With bootstrap over, a queued batch can also clear the pause flags, giving governance a scheduled route
    /// to resume.
    function test_theTimelockCanLiftAPause() public {
        vm.prank(guardian);
        riskConfig.setPaused(true, true);
        vm.prank(gov);
        riskConfig.finishBootstrap();

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(RiskConfig.setPaused, (false, false));
        bytes32 salt = keccak256("unpause");
        vm.prank(gov);
        riskConfig.schedule(calls, salt, keccak256("rationale: incident closed"));
        vm.warp(block.timestamp + 1 days);
        vm.prank(gov);
        riskConfig.execute(calls, salt);

        assertFalse(riskConfig.newLoansPaused());
        assertFalse(riskConfig.liquidationsPaused());
    }

    // =========================================================================
    // Parameter validation and ownership
    // =========================================================================

    function test_invalidTierConfigRejected() public {
        vm.prank(gov);
        vm.expectRevert(RiskConfig.InvalidBps.selector);
        riskConfig.setTierConfig(
            3, IRiskConfig.TierConfig({maxLtvBps: 8000, liqLtvBps: 7000, closedHaircutBps: 0, enabled: true})
        );
    }

    function test_degenerateParamsRejected() public {
        vm.startPrank(gov);
        vm.expectRevert(RiskConfig.InvalidParams.selector);
        riskConfig.setLoanParams(
            IRiskConfig.LoanParams({
                minInterestPeriod: 3 days, graceWindow: 24 hours, sequencerGrace: 1 hours, maxSlicesPerLoan: 0
            })
        );
        vm.expectRevert(RiskConfig.InvalidParams.selector);
        riskConfig.setAuctionParams(
            IRiskConfig.AuctionParams({
                startPremiumBps: 300,
                floorBpsRegular: 7000,
                floorBpsClosed: 8500,
                duration: 0,
                penaltyBps: 300,
                keeperShareBps: 3334,
                lenderPenaltyShareBps: 5000
            })
        );
        vm.expectRevert(RiskConfig.InvalidParams.selector);
        riskConfig.setRefinanceParams(IRiskConfig.RefinanceParams({capSpreadBps: 400, duration: 0}));
        vm.stopPrank();

        // None of the refused calls touched storage; the fixture's values are all still in place.
        assertEq(riskConfig.loanParams().maxSlicesPerLoan, 32);
        assertEq(riskConfig.auctionParams().duration, 45 minutes);
        assertEq(riskConfig.refinanceParams().duration, 4 hours);
    }

    function test_addressSettersRefuseTheZeroAddress() public {
        vm.startPrank(gov);
        vm.expectRevert(RiskConfig.ZeroAddress.selector);
        riskConfig.setEligibilityAdapter(address(0));
        vm.expectRevert(RiskConfig.ZeroAddress.selector);
        riskConfig.setLoanTokenEnabled(address(0), true);
        vm.expectRevert(RiskConfig.ZeroAddress.selector);
        riskConfig.setVaultWhitelisted(address(0), true);
        vm.expectRevert(RiskConfig.ZeroAddress.selector);
        riskConfig.setAttestationIssuer(address(0), true);
        vm.stopPrank();
    }

    function test_anOwnershipHandoverCanBeCancelled() public {
        address next = makeAddr("next");
        vm.startPrank(gov);
        vm.expectRevert(RiskConfig.NoPendingOwner.selector);
        riskConfig.cancelOwnershipTransfer();
        vm.expectRevert(RiskConfig.ZeroAddress.selector);
        riskConfig.transferOwnership(address(0));

        riskConfig.transferOwnership(next);
        riskConfig.cancelOwnershipTransfer();
        vm.stopPrank();
        assertEq(riskConfig.pendingOwner(), address(0));

        vm.prank(next);
        vm.expectRevert(RiskConfig.NotPendingOwner.selector);
        riskConfig.acceptOwnership();
        assertEq(riskConfig.owner(), gov);
    }

    // =========================================================================
    // Credentials and eligibility
    // =========================================================================

    function test_attestationExpiryAndRevocation() public {
        assertTrue(permissions.isEligible(borrower, Permissions.BORROWER));
        vm.warp(block.timestamp + 366 days);
        assertFalse(permissions.isEligible(borrower, Permissions.BORROWER));

        vm.prank(issuer);
        credentials.attest(borrower, Permissions.BORROWER, "LT", 2, uint64(block.timestamp + 30 days));
        assertTrue(permissions.isEligible(borrower, Permissions.BORROWER));
        vm.prank(issuer);
        credentials.revoke(borrower, Permissions.BORROWER);
        assertFalse(permissions.isEligible(borrower, Permissions.BORROWER));
    }

    function test_revokeNeedsALiveRecord() public {
        vm.prank(issuer);
        vm.expectRevert(CredentialRegistry.NoActiveRecord.selector);
        credentials.revoke(makeAddr("nobody"), Permissions.BORROWER);

        vm.prank(issuer);
        credentials.revoke(borrower, Permissions.BORROWER);
        vm.prank(issuer);
        vm.expectRevert(CredentialRegistry.NoActiveRecord.selector);
        credentials.revoke(borrower, Permissions.BORROWER);
    }

    function test_attestManyWritesARecordPerAccount() public {
        address[] memory accounts = new address[](2);
        accounts[0] = makeAddr("a");
        accounts[1] = makeAddr("b");
        bytes2[] memory jurisdictions = new bytes2[](2);
        jurisdictions[0] = "LT";
        jurisdictions[1] = "DE";
        uint8[] memory classes = new uint8[](2);
        classes[0] = 2;
        classes[1] = 3;

        vm.prank(issuer);
        bytes32[] memory uids = credentials.attestMany(
            accounts, Permissions.BORROWER, jurisdictions, classes, uint64(block.timestamp + 30 days)
        );
        assertEq(uids.length, 2);
        assertTrue(uids[0] != uids[1]);
        assertTrue(permissions.isEligible(accounts[0], Permissions.BORROWER));
        assertTrue(permissions.isEligible(accounts[1], Permissions.BORROWER));
        assertEq(credentials.attestation(accounts[1], Permissions.BORROWER).jurisdictionClass, bytes2("DE"));

        uint8[] memory short = new uint8[](1);
        vm.prank(issuer);
        vm.expectRevert(CredentialRegistry.LengthMismatch.selector);
        credentials.attestMany(accounts, Permissions.BORROWER, jurisdictions, short, uint64(block.timestamp + 30 days));
    }

    function test_revokeManyRevokesEachAccount() public {
        address[] memory accounts = new address[](2);
        accounts[0] = lender1;
        accounts[1] = lender2;

        vm.prank(lender1);
        vm.expectRevert(CredentialRegistry.NotIssuer.selector);
        credentials.revokeMany(accounts, Permissions.LENDER_PROFESSIONAL);

        vm.prank(issuer);
        credentials.revokeMany(accounts, Permissions.LENDER_PROFESSIONAL);
        assertFalse(permissions.isLender(lender1));
        assertFalse(permissions.isLender(lender2));
        assertTrue(permissions.isLender(lender3), "a lender left out of the batch keeps its credential");

        // Nothing live is left for either account, so repeating the batch reverts.
        vm.prank(issuer);
        vm.expectRevert(CredentialRegistry.NoActiveRecord.selector);
        credentials.revokeMany(accounts, Permissions.LENDER_PROFESSIONAL);
    }

    function test_attestRefusesTheZeroAccount() public {
        vm.prank(issuer);
        vm.expectRevert(CredentialRegistry.ZeroAccount.selector);
        credentials.attest(address(0), Permissions.BORROWER, "LT", 2, uint64(block.timestamp + 30 days));
    }

    function test_isBorrowerMatchesTheBorrowerRole() public {
        assertTrue(permissions.isBorrower(borrower));
        assertFalse(permissions.isBorrower(lender1));
    }

    function test_removingIssuerInvalidatesItsAttestations() public {
        vm.prank(gov);
        riskConfig.setAttestationIssuer(issuer, false);
        assertFalse(permissions.isLender(lender1));
    }

    // =========================================================================
    // Slice notes
    // =========================================================================

    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    function test_sliceTransferGatedByEligibility() public {
        uint256 loanId = _originateExample();
        uint256 sliceId = hub.getLoan(loanId).sliceIds[0];
        address stranger = makeAddr("stranger");
        vm.prank(lender1);
        vm.expectRevert(abi.encodeWithSelector(IPermissionRegistry.NotLender.selector, stranger));
        sliceNote.transferFrom(lender1, stranger, sliceId);
        vm.prank(lender1);
        sliceNote.transferFrom(lender1, lender2, sliceId);
        assertEq(sliceNote.ownerOf(sliceId), lender2);
    }

    function test_sliceTokenSignalsMetadataUpdates() public {
        assertTrue(sliceNote.supportsInterface(0x49064906), "supports ERC-4906");
        assertTrue(sliceNote.supportsInterface(0x80ac58cd), "supports ERC-721");

        vm.expectEmit(address(sliceNote));
        emit BatchMetadataUpdate(0, type(uint256).max);
        vm.prank(gov);
        sliceNote.setBaseURI("https://onspatial.org/slices/");
    }

    function test_sliceTokenExists() public {
        uint256 loanId = _originateExample();
        uint256 sliceId = hub.getLoan(loanId).sliceIds[0];
        assertTrue(sliceNote.exists(sliceId));
        assertFalse(sliceNote.exists(sliceId + 1000));
    }

    function test_sliceNoteRefusesAZeroHub() public {
        SliceNote fresh = new SliceNote(permissions, riskConfig);
        vm.prank(gov);
        vm.expectRevert(SliceNote.ZeroHub.selector);
        fresh.setDesk(address(0));
    }

    // =========================================================================
    // Fee vault and wiring
    // =========================================================================

    function test_treasuryWithdrawOnlyGovernance() public {
        _originateExample();
        vm.prank(lender1);
        vm.expectRevert();
        feeVault.withdraw(usdg, lender1, 1);
        vm.prank(gov);
        feeVault.withdraw(usdg, gov, 50e6);
        assertEq(usdg.balanceOf(gov), 50e6);
    }

    function test_treasuryMaxAmountSweepsTheWholeBalance() public {
        _originateExample();
        uint256 held = usdg.balanceOf(address(feeVault));
        assertGt(held, 0);
        vm.prank(gov);
        feeVault.withdraw(usdg, gov, type(uint256).max);
        assertEq(usdg.balanceOf(address(feeVault)), 0);
        assertEq(usdg.balanceOf(gov), held);
    }

    function test_treasuryRefusesTheZeroRecipient() public {
        _originateExample();
        vm.prank(gov);
        vm.expectRevert(FeeVault.ZeroRecipient.selector);
        feeVault.withdraw(usdg, address(0), 1);
    }

    function test_wireIsOneShot() public {
        vm.prank(gov);
        vm.expectRevert();
        hub.wire(address(1), address(2), idle);
    }
}
