// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {LoanTypes, Permissions} from "../src/libraries/LoanTypes.sol";
import {ICreditHub} from "../src/interfaces/ICreditHub.sol";
import {IPermissionRegistry} from "../src/interfaces/IPermissionRegistry.sol";
import {QuoteBook} from "../src/QuoteBook.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IRiskConfig} from "../src/interfaces/IRiskConfig.sol";
import {MockERC20} from "../src/mocks/Mocks.sol";

/// @title OriginationTest
/// @notice Covers how a borrow request becomes a loan. That includes multi-lender fills, the origination fee and
///         slice bookkeeping, every ground on which the hub refuses a set of offers, requests submitted by a
///         relayer or submitted twice, funding drawn from the reserve adapter, moving slice notes between
///         holders, and the checks on sequencer uptime and on oversized collateral amounts.
contract OriginationTest is BaseTest {
    function test_originate_fundsFromThreeLenders() public {
        uint256 borrowerUsdgBefore = usdg.balanceOf(borrower);
        uint256 loanId = _originateExample();

        LoanTypes.Loan memory L = hub.getLoan(loanId);
        assertEq(L.borrower, borrower);
        assertEq(L.collateralAmount, 250e18);
        assertEq(L.principal, 20_000e6);
        assertEq(uint8(L.status), uint8(LoanTypes.LoanStatus.Active));
        assertEq(L.sliceIds.length, 3);
        assertEq(L.maturity, block.timestamp + 30 days);

        // The borrower receives 20,000 less the 25 bps origination fee. That fee, 50 USDG, goes to the fee vault.
        assertEq(usdg.balanceOf(borrower) - borrowerUsdgBefore, 20_000e6 - 50e6);
        assertEq(usdg.balanceOf(address(feeVault)), 50e6);
        assertEq(nvda.balanceOf(address(hub)), 250e18);

        // Each lender that signed an offer is minted exactly one slice note.
        assertEq(sliceNote.ownerOf(L.sliceIds[0]), lender1);
        assertEq(sliceNote.ownerOf(L.sliceIds[1]), lender2);
        assertEq(sliceNote.ownerOf(L.sliceIds[2]), lender3);

        // Weighting each rate by its principal gives (5,000 x 850 + 10,000 x 890 + 5,000 x 900) / 20,000, which
        // is 882.5 bps and rounds down to 882. The rollover market works this out because it opens its rate
        // auction at that figure.
        assertEq(rollover.blendedAprBps(loanId), 882);
        // LTV is measured on total debt rather than bare principal. Debt already includes the minimum three days
        // of interest, 14.51 USDG, so the ratio is 20,014.51 over 44,100, or 4,538 bps.
        assertEq(hub.ltvBps(loanId), 4538);
        // With a 7,000 bps liquidation threshold the health factor is 44,100 x 0.7 divided by 20,014.51, close
        // to 1.542.
        (uint256 p, uint256 i) = hub.debtOf(loanId);
        assertEq(hub.healthFactor(loanId), 44_100e6 * 7000 * 1e18 / (10_000 * (p + i)));
        assertEq(hub.exposure(address(nvda)), 20_000e6);
    }

    function test_originate_refusesLtvOverTierLimit() public {
        // The tier allows borrowing up to 24,255 USDG against 44,100 of collateral. Asking for 25,000 puts the
        // ratio at 5,668 bps, so the hub refuses it, even though this lender would have accepted up to 6,000.
        LoanTypes.LendOffer[] memory offers = new LoanTypes.LendOffer[](1);
        bytes[] memory sigs = new bytes[](1);
        offers[0] = _offer(lender1, 25_000e6, 850, 1, 0);
        offers[0].maxLtvBps = 6000;
        sigs[0] = _sign(lender1Pk, offers[0]);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(ICreditHub.LtvTooHigh.selector, 5668, 5500));
        hub.originate(_request(250e18, 25_000e6, 900), "", offers, sigs);
    }

    function test_originate_refusesUncredentialedLender() public {
        uint256 strangerPk = 0x5717;
        address stranger = vm.addr(strangerPk);
        usdg.mint(stranger, 100_000e6);
        vm.prank(stranger);
        usdg.approve(address(hub), type(uint256).max);

        LoanTypes.LendOffer[] memory offers = new LoanTypes.LendOffer[](1);
        bytes[] memory sigs = new bytes[](1);
        offers[0] = _offer(stranger, 20_000e6, 850, 1, 0);
        sigs[0] = _sign(strangerPk, offers[0]);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(IPermissionRegistry.NotLender.selector, stranger));
        hub.originate(_request(250e18, 20_000e6, 900), "", offers, sigs);
    }

    function test_originate_refusesRevokedBorrower() public {
        vm.prank(issuer);
        credentials.revoke(borrower, Permissions.BORROWER);
        LoanTypes.LendOffer[] memory offers = new LoanTypes.LendOffer[](1);
        bytes[] memory sigs = new bytes[](1);
        offers[0] = _offer(lender1, 20_000e6, 850, 1, 0);
        sigs[0] = _sign(lender1Pk, offers[0]);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(IPermissionRegistry.NotEligible.selector, borrower, Permissions.BORROWER));
        hub.originate(_request(250e18, 20_000e6, 900), "", offers, sigs);
    }

    function test_originate_refusesOfferPricedAboveBorrowerCap() public {
        LoanTypes.LendOffer[] memory offers = new LoanTypes.LendOffer[](1);
        bytes[] memory sigs = new bytes[](1);
        offers[0] = _offer(lender1, 20_000e6, 950, 1, 0);
        sigs[0] = _sign(lender1Pk, offers[0]);
        bytes32 h = _offerDigest(offers[0]);
        LoanTypes.BorrowRequest memory r = _request(250e18, 20_000e6, 900);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(ICreditHub.OfferMismatch.selector, h));
        hub.originate(r, "", offers, sigs);
    }

    function test_originate_refusesCancelledOffer() public {
        LoanTypes.LendOffer[] memory offers = new LoanTypes.LendOffer[](1);
        bytes[] memory sigs = new bytes[](1);
        offers[0] = _offer(lender1, 20_000e6, 850, 42, 0);
        sigs[0] = _sign(lender1Pk, offers[0]);
        vm.prank(lender1);
        hub.cancel(42);
        bytes32 h = _offerDigest(offers[0]);
        LoanTypes.BorrowRequest memory r = _request(250e18, 20_000e6, 900);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(QuoteBook.OfferWasCancelled.selector, h));
        hub.originate(r, "", offers, sigs);
    }

    function test_originate_reusableOfferFundsTwoLoans() public {
        LoanTypes.LendOffer[] memory offers = new LoanTypes.LendOffer[](1);
        bytes[] memory sigs = new bytes[](1);
        offers[0] = _offer(lender1, 50_000e6, 850, 7, 0);
        offers[0].collateralToken = address(uint160(1)); // wildcard meaning any collateral in tier 1
        sigs[0] = _sign(lender1Pk, offers[0]);

        vm.prank(borrower);
        hub.originate(_request(250e18, 20_000e6, 900), "", offers, sigs);
        assertEq(hub.remainingCapacity(offers[0]), 30_000e6);

        LoanTypes.BorrowRequest memory r2 = _request(250e18, 20_000e6, 900);
        r2.salt = bytes32(uint256(2));
        vm.prank(borrower);
        hub.originate(r2, "", offers, sigs);
        assertEq(hub.remainingCapacity(offers[0]), 10_000e6);
        assertEq(hub.loanCount(), 2);
    }

    function test_originate_reportsWhyOffersWereRefused() public {
        LoanTypes.BorrowRequest memory r = _request(250e18, 20_000e6, 900);

        // Two offers but only one signature: the arrays are compared before any offer is examined.
        LoanTypes.LendOffer[] memory offers = new LoanTypes.LendOffer[](2);
        bytes[] memory sigs = new bytes[](1);
        offers[0] = _offer(lender1, 20_000e6, 850, 1, 0);
        offers[1] = _offer(lender2, 20_000e6, 890, 1, 0);
        sigs[0] = _sign(lender1Pk, offers[0]);
        vm.prank(borrower);
        vm.expectRevert(ICreditHub.LengthMismatch.selector);
        hub.originate(r, "", offers, sigs);

        // The first offer already covers all 20,000, so adding the second would fund more than was asked for.
        sigs = new bytes[](2);
        sigs[0] = _sign(lender1Pk, offers[0]);
        sigs[1] = _sign(lender2Pk, offers[1]);
        vm.prank(borrower);
        vm.expectRevert(ICreditHub.OverFilled.selector);
        hub.originate(r, "", offers, sigs);

        // An offer that has lent its full principalMax has nothing left. A later request relying on it fails
        // with an error that identifies the offer, rather than being partly funded.
        LoanTypes.LendOffer[] memory one = new LoanTypes.LendOffer[](1);
        bytes[] memory oneSig = new bytes[](1);
        one[0] = _offer(lender1, 20_000e6, 850, 2, 0);
        oneSig[0] = _sign(lender1Pk, one[0]);
        vm.prank(borrower);
        hub.originate(r, "", one, oneSig);
        assertEq(hub.remainingCapacity(one[0]), 0);

        r.salt = bytes32(uint256(2));
        bytes32 h = _offerDigest(one[0]);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(ICreditHub.OfferExhausted.selector, h));
        hub.originate(r, "", one, oneSig);
    }

    function test_originate_relayedRequestRequiresBorrowerSignature() public {
        address relayer = makeAddr("relayer");
        vm.prank(issuer);
        credentials.attest(relayer, Permissions.RELAYER, "LT", 0, uint64(block.timestamp + 30 days));

        LoanTypes.LendOffer[] memory offers = new LoanTypes.LendOffer[](1);
        bytes[] memory sigs = new bytes[](1);
        offers[0] = _offer(lender1, 20_000e6, 850, 1, 0);
        sigs[0] = _sign(lender1Pk, offers[0]);
        LoanTypes.BorrowRequest memory r = _request(250e18, 20_000e6, 900);

        vm.prank(relayer);
        vm.expectRevert(ICreditHub.BadRequestSignature.selector);
        hub.originate(r, "", offers, sigs);

        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(borrowerPk, hub.requestHash(r));
        vm.prank(relayer);
        uint256 loanId = hub.originate(r, abi.encodePacked(rr, ss, v), offers, sigs);
        assertEq(hub.getLoan(loanId).borrower, borrower);
    }

    /// With the NVDA cap cut to 30,000 USDG, the first 20,000 loan fits but a second one would breach it.
    function test_originate_honoursExposureCap() public {
        vm.prank(gov);
        riskConfig.setTokenConfig(address(nvda), IRiskConfig.TokenConfig({tier: 1, exposureCap: 30_000e6, enabled: true}));
        _originateExample();
        LoanTypes.LendOffer[] memory offers = new LoanTypes.LendOffer[](1);
        bytes[] memory sigs = new bytes[](1);
        offers[0] = _offer(lender1, 20_000e6, 850, 9, 0);
        sigs[0] = _sign(lender1Pk, offers[0]);
        LoanTypes.BorrowRequest memory r2 = _request(250e18, 20_000e6, 900);
        r2.salt = bytes32(uint256(2));
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(ICreditHub.ExposureCapExceeded.selector, address(nvda)));
        hub.originate(r2, "", offers, sigs);
    }

    function test_originate_haltedByGuardianPause() public {
        vm.prank(guardian);
        riskConfig.setPaused(true, false);
        LoanTypes.LendOffer[] memory offers = new LoanTypes.LendOffer[](1);
        bytes[] memory sigs = new bytes[](1);
        offers[0] = _offer(lender1, 20_000e6, 850, 1, 0);
        sigs[0] = _sign(lender1Pk, offers[0]);
        vm.prank(borrower);
        vm.expectRevert(ICreditHub.NewLoansPaused.selector);
        hub.originate(_request(250e18, 20_000e6, 900), "", offers, sigs);
    }

    function test_originate_drawsFromReserve() public {
        // lender1 puts 50,000 USDG into the reserve adapter, then signs an offer flagged to lend out of it.
        vm.startPrank(lender1);
        usdg.approve(address(idle), type(uint256).max);
        idle.deposit(50_000e6);
        vm.stopPrank();
        assertEq(idle.balanceOf(lender1), 50_000e6);

        LoanTypes.LendOffer[] memory offers = new LoanTypes.LendOffer[](1);
        bytes[] memory sigs = new bytes[](1);
        offers[0] = _offer(lender1, 20_000e6, 850, 3, LoanTypes.FLAG_PARK_IDLE);
        sigs[0] = _sign(lender1Pk, offers[0]);
        uint256 walletBefore = usdg.balanceOf(lender1);
        vm.prank(borrower);
        uint256 loanId = hub.originate(_request(250e18, 20_000e6, 900), "", offers, sigs);

        assertEq(usdg.balanceOf(lender1), walletBefore, "lender wallet should not change");
        assertEq(idle.balanceOf(lender1), 30_000e6, "funds should come out of the reserve");

        // On repayment the principal and interest go back into the reserve position instead of the wallet.
        vm.warp(block.timestamp + 10 days);
        (uint256 p, uint256 i) = hub.debtOf(loanId);
        vm.prank(borrower);
        hub.repay(loanId, p + i);
        assertGt(idle.balanceOf(lender1), 50_000e6);
    }

    function test_originate_refusesReusedRequest() public {
        LoanTypes.LendOffer[] memory offers = new LoanTypes.LendOffer[](1);
        bytes[] memory sigs = new bytes[](1);
        offers[0] = _offer(lender1, 50_000e6, 850, 7, 0);
        sigs[0] = _sign(lender1Pk, offers[0]);

        LoanTypes.BorrowRequest memory r = _request(250e18, 20_000e6, 900);
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(borrowerPk, hub.requestHash(r));
        bytes memory borrowerSig = abi.encodePacked(rr, ss, v);

        address relayer = makeAddr("relayer");
        vm.prank(issuer);
        credentials.attest(relayer, Permissions.RELAYER, "LT", 0, uint64(block.timestamp + 30 days));

        vm.prank(relayer);
        hub.originate(r, borrowerSig, offers, sigs);

        // A request hash is marked as used the first time it fills. Submitting the identical signed request a
        // second time must fail, otherwise a relayer could open another loan off the borrower's approval.
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ICreditHub.RequestAlreadyUsed.selector, hub.requestHash(r)));
        hub.originate(r, borrowerSig, offers, sigs);
        assertEq(hub.loanCount(), 1);
    }

    function test_cancelRequestInvalidatesSignedRequest() public {
        LoanTypes.BorrowRequest memory r = _request(250e18, 20_000e6, 900);
        bytes32 h = hub.requestHash(r);

        vm.prank(lender1);
        vm.expectRevert(ICreditHub.NotBorrower.selector);
        hub.cancelRequest(r);

        vm.prank(borrower);
        hub.cancelRequest(r);
        assertTrue(hub.requestUsed(h));

        LoanTypes.LendOffer[] memory offers = new LoanTypes.LendOffer[](1);
        bytes[] memory sigs = new bytes[](1);
        offers[0] = _offer(lender1, 20_000e6, 850, 1, 0);
        sigs[0] = _sign(lender1Pk, offers[0]);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(ICreditHub.RequestAlreadyUsed.selector, h));
        hub.originate(r, "", offers, sigs);
    }

    function test_originate_refusesTooManyLenders() public {
        vm.prank(gov);
        riskConfig.setLoanParams(
            IRiskConfig.LoanParams({
                minInterestPeriod: 3 days, graceWindow: 24 hours, sequencerGrace: 1 hours, maxSlicesPerLoan: 2
            })
        );

        LoanTypes.LendOffer[] memory offers = new LoanTypes.LendOffer[](3);
        bytes[] memory sigs = new bytes[](3);
        offers[0] = _offer(lender1, 5_000e6, 850, 1, 0);
        offers[1] = _offer(lender2, 10_000e6, 890, 1, 0);
        offers[2] = _offer(lender3, 5_000e6, 900, 1, 0);
        sigs[0] = _sign(lender1Pk, offers[0]);
        sigs[1] = _sign(lender2Pk, offers[1]);
        sigs[2] = _sign(lender3Pk, offers[2]);

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(ICreditHub.TooManySlices.selector, 2));
        hub.originate(_request(250e18, 20_000e6, 900), "", offers, sigs);

        // Splitting the same 20,000 between two lenders stays within the limit, so this one succeeds.
        LoanTypes.LendOffer[] memory two = new LoanTypes.LendOffer[](2);
        bytes[] memory twoSigs = new bytes[](2);
        two[0] = _offer(lender1, 10_000e6, 850, 2, 0);
        two[1] = _offer(lender2, 10_000e6, 890, 2, 0);
        twoSigs[0] = _sign(lender1Pk, two[0]);
        twoSigs[1] = _sign(lender2Pk, two[1]);
        vm.prank(borrower);
        uint256 loanId = hub.originate(_request(250e18, 20_000e6, 900), "", two, twoSigs);
        assertEq(hub.getLoan(loanId).sliceIds.length, 2);
    }

    function test_sliceTransferRedirectsRepayment() public {
        uint256 loanId = _originateExample();
        uint256 sliceId = hub.getLoan(loanId).sliceIds[0];
        assertEq(hub.getSlice(sliceId).lender, lender1);

        vm.prank(lender1);
        sliceNote.transferFrom(lender1, lender2, sliceId);
        assertEq(sliceNote.ownerOf(sliceId), lender2);
        assertEq(hub.getSlice(sliceId).lender, lender2, "slice lender should track the note owner");

        vm.warp(block.timestamp + 30 days);
        uint256 l1Before = usdg.balanceOf(lender1);
        uint256 l2Before = usdg.balanceOf(lender2);
        (uint256 p, uint256 i) = hub.debtOf(loanId);
        vm.prank(borrower);
        hub.repay(loanId, p + i);

        // lender1 sold its only slice, so receives nothing. lender2 now holds two slices and is paid for both.
        assertEq(usdg.balanceOf(lender1), l1Before, "seller should receive no repayment");
        assertGt(usdg.balanceOf(lender2) - l2Before, 15_000e6, "buyer should be paid for the bought slice");
    }

    function test_sliceTransferNeedsEligibleRecipientAndNoteCallback() public {
        uint256 loanId = _originateExample();
        uint256 sliceId = hub.getLoan(loanId).sliceIds[0];

        address stranger = makeAddr("stranger");
        vm.prank(lender1);
        vm.expectRevert(abi.encodeWithSelector(IPermissionRegistry.NotLender.selector, stranger));
        sliceNote.transferFrom(lender1, stranger, sliceId);
        assertEq(hub.getSlice(sliceId).lender, lender1);

        // Only the slice note contract, calling in during a transfer, can change who a slice pays.
        vm.prank(lender2);
        vm.expectRevert(ICreditHub.NotSliceNote.selector);
        hub.onSliceTransfer(sliceId, lender2);
    }

    function test_originate_waitsOutSequencerRestartGrace() public {
        // The sequencer restarted ten minutes ago, but the configured grace period is an hour.
        sequencer.setWithTimestamps(0, block.timestamp - 10 minutes, block.timestamp);

        LoanTypes.LendOffer[] memory offers = new LoanTypes.LendOffer[](1);
        bytes[] memory sigs = new bytes[](1);
        offers[0] = _offer(lender1, 20_000e6, 850, 1, 0);
        sigs[0] = _sign(lender1Pk, offers[0]);

        vm.prank(borrower);
        vm.expectRevert(ICreditHub.SequencerGrace.selector);
        hub.originate(_request(250e18, 20_000e6, 900), "", offers, sigs);

        // After another hour the identical request goes through.
        vm.warp(block.timestamp + 1 hours);
        vm.prank(borrower);
        uint256 loanId = hub.originate(_request(250e18, 20_000e6, 900), "", offers, sigs);
        assertEq(hub.getLoan(loanId).principal, 20_000e6);
    }

    /// The uptime feed returns 1 while the sequencer is offline, and no loan can be opened in that state.
    function test_originate_refusedWhileSequencerOffline() public {
        sequencer.setWithTimestamps(1, block.timestamp - 7 days, block.timestamp);

        LoanTypes.LendOffer[] memory offers = new LoanTypes.LendOffer[](1);
        bytes[] memory sigs = new bytes[](1);
        offers[0] = _offer(lender1, 20_000e6, 850, 1, 0);
        sigs[0] = _sign(lender1Pk, offers[0]);

        vm.prank(borrower);
        vm.expectRevert(ICreditHub.SequencerGrace.selector);
        hub.originate(_request(250e18, 20_000e6, 900), "", offers, sigs);
    }

    function test_originate_refusesCollateralBeyondUint128() public {
        // The loan record keeps collateral in a uint128 field. A silent cast would take the whole amount from
        // the borrower but store only its lower bits, locking away the difference, so SafeCast has to revert.
        uint256 huge = uint256(type(uint128).max) + 1;
        nvda.mint(borrower, huge);

        LoanTypes.LendOffer[] memory offers = new LoanTypes.LendOffer[](1);
        bytes[] memory sigs = new bytes[](1);
        offers[0] = _offer(lender1, 20_000e6, 850, 1, 0);
        sigs[0] = _sign(lender1Pk, offers[0]);

        LoanTypes.BorrowRequest memory r = _request(huge, 20_000e6, 900);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 128, huge));
        hub.originate(r, "", offers, sigs);
    }

    /// Turning on another loan token must not allow NVDA to back it. The guard prices NVDA in USDG units with
    /// 6 decimals, so comparing an 18-decimal principal against that value would understate the LTV by a factor
    /// of 10^12 and let through a loan with almost no real collateral cover.
    function test_originate_refusesLoanTokenOutsideFeedQuote() public {
        MockERC20 eurg = new MockERC20("Euro Global", "EURG", 18);
        vm.prank(gov);
        riskConfig.setLoanTokenEnabled(address(eurg), true);
        eurg.mint(lender1, 1_000_000e18);
        vm.prank(lender1);
        eurg.approve(address(hub), type(uint256).max);

        LoanTypes.LendOffer memory o = _offer(lender1, 20_000e18, 850, 1, 0);
        o.loanToken = address(eurg);
        LoanTypes.LendOffer[] memory offers = new LoanTypes.LendOffer[](1);
        bytes[] memory sigs = new bytes[](1);
        offers[0] = o;
        sigs[0] = _sign(lender1Pk, o);

        LoanTypes.BorrowRequest memory r = _request(250e18, 20_000e18, 900);
        r.loanToken = address(eurg);

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(ICreditHub.LoanTokenMismatch.selector, address(eurg), address(usdg)));
        hub.originate(r, "", offers, sigs);
    }

    function test_addCollateralRefusesAmountBeyondUint128() public {
        uint256 loanId = _originateExample();
        uint256 huge = uint256(type(uint128).max) + 1;
        nvda.mint(borrower, huge);

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 128, huge));
        hub.addCollateral(loanId, huge);
    }
}
