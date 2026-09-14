// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "./Base.t.sol";
import {CreditHub} from "../src/CreditHub.sol";
import {LoanTypes} from "../src/libraries/LoanTypes.sol";
import {MockERC20, MockStockToken} from "../src/mocks/Mocks.sol";

/// @notice Fuzzer target that drives a single open loan with random repayments, collateral additions and time
///         jumps, so the bookkeeping checks run against histories nobody scripted. Each action swallows its own
///         reverts: the point is to inspect every state the hub ends up in, not to judge which inputs it refuses.
contract LoanActionHandler is Test {
    CreditHub internal hub;
    MockERC20 internal usdg;
    MockStockToken internal nvda;
    address internal borrower;
    uint256 internal loanId;

    constructor(CreditHub hub_, MockERC20 usdg_, MockStockToken nvda_, address borrower_, uint256 loanId_) {
        hub = hub_;
        usdg = usdg_;
        nvda = nvda_;
        borrower = borrower_;
        loanId = loanId_;
    }

    function repay(uint256 amount) external {
        amount = bound(amount, 1, 25_000e6);
        usdg.mint(borrower, amount);
        vm.prank(borrower);
        try hub.repay(loanId, amount) {} catch {}
    }

    function addCollateral(uint256 amount) external {
        amount = bound(amount, 1, 100e18);
        nvda.mint(borrower, amount);
        vm.prank(borrower);
        try hub.addCollateral(loanId, amount) {} catch {}
    }

    function passTime(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1 minutes, 5 days));
    }
}

/// @notice Bookkeeping rules that must survive any sequence of actions. Each loan's principal matches the total
///         of its slices; recorded exposure on NVDA matches the principal outstanding against it; the hub's
///         collateral balance is at least what the loans say is escrowed; and no USDG sits idle in the hub once a
///         transaction finishes.
abstract contract BookkeepingChecks is BaseTest {
    /// @dev Loops over all loans ever created and asserts the four rules together.
    function _checkBooks() internal view {
        uint256 outstanding;
        uint256 escrowed;
        uint256 count = hub.loanCount();
        for (uint256 id = 1; id <= count; ++id) {
            LoanTypes.Loan memory loan = hub.getLoan(id);
            uint256 slicesTotal;
            for (uint256 k = 0; k < loan.sliceIds.length; ++k) {
                slicesTotal += hub.getSlice(loan.sliceIds[k]).principal;
            }
            assertEq(slicesTotal, loan.principal, "slice principals should add up to the loan principal");
            outstanding += loan.principal;
            escrowed += loan.collateralAmount;
        }
        assertEq(hub.exposure(address(nvda)), outstanding, "exposure should equal the principal still owed");
        assertGe(nvda.balanceOf(address(hub)), escrowed, "hub must hold at least the recorded collateral");
        assertEq(usdg.balanceOf(address(hub)), 0, "no USDG should remain in the hub after a call");
    }
}

/// @notice Stateful run: the fuzzer strings together handler calls and the rules are rechecked after each one.
contract LedgerInvariantTest is BookkeepingChecks {
    LoanActionHandler internal handler;

    function setUp() public override {
        super.setUp();
        uint256 loanId = _originateExample();
        handler = new LoanActionHandler(hub, usdg, nvda, borrower, loanId);
        targetContract(address(handler));
    }

    function invariant_booksBalance() public view {
        _checkBooks();
    }
}

/// @notice Single-loan scenarios with fuzzed inputs, each finishing with the same bookkeeping rules.
contract LedgerFuzzTest is BookkeepingChecks {
    /// When the borrower pays less than the full debt, the amount is shared out by slice weight and the final
    /// slice absorbs any rounding leftover. However big the payment, the slices must still sum to the loan.
    function testFuzz_partialPaymentKeepsSlicesInStep(uint256 payment, uint256 elapsed) public {
        uint256 loanId = _originateExample();
        vm.warp(block.timestamp + bound(elapsed, 0, 29 days));

        (uint256 owedPrincipal, uint256 owedInterest) = hub.debtOf(loanId);
        payment = bound(payment, 1, owedPrincipal + owedInterest - 1);
        usdg.mint(borrower, payment);
        vm.prank(borrower);
        hub.repay(loanId, payment);

        assertEq(uint8(hub.getLoan(loanId).status), uint8(LoanTypes.LoanStatus.Active));
        _checkBooks();
    }

    /// However the 20,000 USDG is divided between the three lenders, a full repayment at maturity should close
    /// the loan, hand back all of the collateral and leave the books empty.
    function testFuzz_fullRepaymentWorksForAnyLenderSplit(uint256 firstShare, uint256 secondShare) public {
        uint256 total = 20_000e6;
        uint256 shareA = bound(firstShare, 1e6, total - 2e6);
        uint256 shareB = bound(secondShare, 1e6, total - shareA - 1e6);
        uint256 shareC = total - shareA - shareB;

        LoanTypes.LendOffer[] memory offers = new LoanTypes.LendOffer[](3);
        bytes[] memory sigs = new bytes[](3);
        offers[0] = _offer(lender1, shareA, 850, 31, 0);
        offers[1] = _offer(lender2, shareB, 890, 31, 0);
        offers[2] = _offer(lender3, shareC, 900, 31, 0);
        sigs[0] = _sign(lender1Pk, offers[0]);
        sigs[1] = _sign(lender2Pk, offers[1]);
        sigs[2] = _sign(lender3Pk, offers[2]);

        vm.prank(borrower);
        uint256 loanId = hub.originate(_request(250e18, total, 900), "", offers, sigs);
        assertEq(hub.exposure(address(nvda)), total);

        vm.warp(block.timestamp + 30 days);
        (uint256 owedPrincipal, uint256 owedInterest) = hub.debtOf(loanId);
        usdg.mint(borrower, owedPrincipal + owedInterest);
        uint256 nvdaBefore = nvda.balanceOf(borrower);

        vm.prank(borrower);
        hub.repay(loanId, owedPrincipal + owedInterest);

        assertEq(uint8(hub.getLoan(loanId).status), uint8(LoanTypes.LoanStatus.Repaid));
        assertEq(nvda.balanceOf(borrower) - nvdaBefore, 250e18, "borrower should get all 250 NVDA back");
        assertEq(hub.getLoan(loanId).sliceIds.length, 0);
        _checkBooks();
    }

    /// The exposure figure is what the per-token cap is measured against, so it must drop to zero however the
    /// loan closes. In this case the price falls and the collateral is sold at auction.
    function testFuzz_auctionedLoanReleasesExposure(uint256 price8) public {
        uint256 loanId = _originateExample();
        // Any price under roughly 114.37 leaves the loan with a health factor below one at a 7,000 bps
        // liquidation threshold.
        uint256 price = bound(price8, 60_00_000_000, 113_00_000_000);

        vm.warp(block.timestamp + 2 hours); // let the price-move limit window lapse so a large drop is accepted
        _setPrice(price);
        vm.prank(keeper);
        auction.startAuction(loanId);

        vm.prank(liquidator);
        auction.buy(loanId, 250e18, "");

        assertEq(uint8(hub.getLoan(loanId).status), uint8(LoanTypes.LoanStatus.Settled));
        assertEq(hub.exposure(address(nvda)), 0, "exposure must clear even if lenders took a loss");
        assertEq(nvda.balanceOf(address(hub)), 0, "the hub should hold no NVDA afterwards");
        _checkBooks();
    }
}
