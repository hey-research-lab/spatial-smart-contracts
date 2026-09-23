// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";
import {SeedCore} from "./SeedCore.s.sol";
import {RiskConfig} from "../src/RiskConfig.sol";
import {IRiskConfig} from "../src/interfaces/IRiskConfig.sol";
import {CredentialRegistry} from "../src/adapters/CredentialRegistry.sol";
import {SliceNote} from "../src/SliceNote.sol";
import {ReserveAdapter} from "../src/ReserveAdapter.sol";
import {LoanTypes, Permissions} from "../src/libraries/LoanTypes.sol";
import {QuoteHash} from "../src/libraries/QuoteHash.sol";

/// @title QueuedRaise
/// @notice Describes the governance operation that SeedDeep schedules and SeedExecute later carries out. The
///         risk config identifies an operation by hashing its calls together with its salt, so the two scripts
///         take both from this one contract to be sure they agree.
abstract contract QueuedRaise {
    bytes32 internal constant RAISE_SALT = keccak256("spatial.seed.raiseExposureCap");
    bytes32 internal constant RAISE_RATIONALE = keccak256("Raise the Stock Token exposure cap to 2,000,000 USDG");

    /// @dev Two calls: double the collateral token's exposure cap to 2,000,000 USDG, then set the timelock delay
    ///      back to one hour, undoing the short delay that SeedDeep uses to make the wait practical.
    function _capRaiseCalls(address collateralToken) internal pure returns (bytes[] memory calls) {
        calls = new bytes[](2);
        calls[0] = abi.encodeCall(
            RiskConfig.setTokenConfig,
            (collateralToken, IRiskConfig.TokenConfig({tier: 1, exposureCap: 2_000_000e6, enabled: true}))
        );
        calls[1] = abi.encodeCall(RiskConfig.setDelay, (uint256(1 hours)));
    }
}

/// @title SeedDeep
/// @notice Runs after Seed.s.sol on a full deployment and fills in the paths that the hub, the risk config and
///         the liquidation auction were missing.
///         On the hub: an origination relayed for another borrower, a loan funded from parked capital, a 90 day
///         loan, extra collateral, three repayments (one paid by someone other than the borrower), a slice sold
///         on to a second lender, a borrow request withdrawn unfilled, and nonce cancellation both singly and by
///         word.
///         On the risk config: a guardian pause and release, an additional credential issuer, one queued
///         operation kept for SeedExecute and one queued and then cancelled.
///         On the liquidation auction: an ordinary liquidation bought in three pieces during regular trading,
///         and a closed-market liquidation in which one lender who declined closed-market sales is split into a
///         separate loan and another who asked to be repaid in kind receives collateral.
/// @dev Contract addresses come from `deployments/<chainId>.json`. Seed.s.sol consumed nonces 1 to 4, so this
///      script starts nonces and request salts at 20. Example:
///        forge script script/SeedDeep.s.sol --rpc-url robinhood_testnet --broadcast --gas-estimate-multiplier 200 --slow
contract SeedDeep is SeedCore, QueuedRaise {
    /// @dev Keys derived from fixed strings so a later run can sign as the same wallets. These are public and
    ///      therefore unsafe anywhere but a testnet; the wallets only ever hold mock tokens and a dusting of gas.
    uint256 internal constant BORROWER_D_KEY = uint256(keccak256("spatial.seed.borrowerD"));
    uint256 internal constant LENDER_E_KEY = uint256(keccak256("spatial.seed.lenderE"));
    uint256 internal constant BACKUP_ISSUER_KEY = uint256(keccak256("spatial.seed.backupIssuer"));

    /// @dev Native balance sent to the second borrower to cover the single transaction it signs itself.
    uint256 internal constant GAS_GRANT = 0.0005 ether;

    /// @dev Market session codes understood by the mock stock token.
    uint8 internal constant SESSION_CLOSED = 5;
    uint8 internal constant SESSION_REGULAR = 1;

    RiskConfig internal riskConfig;
    CredentialRegistry internal credentials;
    SliceNote internal slices;
    ReserveAdapter internal reserve;

    uint256 internal relayedLoan;
    uint256 internal parkedLoan;
    uint256 internal longLoan;
    uint256 internal plainAuctionLoan;
    uint256 internal flaggedAuctionLoan;
    uint256 internal splitLoan;

    function run() external override {
        uint256 key = vm.envUint("PRIVATE_KEY");
        address self = vm.addr(key);
        _readAddresses();
        _setUpWallets(self, key);
        _openLoans(self, key);
        _serviceLoans(self, key);
        _exerciseGovernance(key);
        _runLiquidations(self, key);
        _logSummary(self);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Stages
    // ---------------------------------------------------------------------------------------------------------

    /// @dev Loads the shared addresses plus the risk config, the credential registry, the slice note and the
    ///      reserve adapter.
    function _readAddresses() internal {
        _readCoreAddresses();
        string memory json = vm.readFile(string.concat("deployments/", vm.toString(block.chainid), ".json"));
        riskConfig = RiskConfig(vm.parseJsonAddress(json, ".RiskConfig"));
        credentials = CredentialRegistry(vm.parseJsonAddress(json, ".CredentialRegistry"));
        slices = SliceNote(vm.parseJsonAddress(json, ".SliceNote"));
        reserve = ReserveAdapter(vm.parseJsonAddress(json, ".ReserveAdapter"));
    }

    /// @dev Pushes a new price so the regular-session freshness check passes, tops up the deployer, approves the
    ///      auction, credentials the second borrower and second lender, and hands the second borrower some
    ///      collateral and gas. The second borrower then approves the hub from its own wallet, since that is
    ///      where its collateral is taken from when the loan opens.
    function _setUpWallets(address self, uint256 key) internal {
        address borrowerD = vm.addr(BORROWER_D_KEY);

        vm.startBroadcast(key);
        priceFeed.set(PRICE_OPEN);
        usdg.mint(self, 500_000e6);
        stock.mint(self, 2_000e18);
        usdg.approve(address(auction), type(uint256).max);

        uint64 validUntil = uint64(block.timestamp + 180 days);
        credentials.attest(borrowerD, Permissions.BORROWER, "LT", 2, validUntil);
        credentials.attest(vm.addr(LENDER_E_KEY), Permissions.LENDER_RETAIL, "IE", 1, validUntil);

        stock.transfer(borrowerD, 80e18);
        (bool sent,) = borrowerD.call{value: GAS_GRANT}("");
        require(sent, "gas grant failed");
        vm.stopBroadcast();

        vm.startBroadcast(BORROWER_D_KEY);
        stock.approve(address(hub), type(uint256).max);
        vm.stopBroadcast();
    }

    /// @dev Opens three loans: a relayed one backed by the borrower's signed request, one whose lender is paid
    ///      out of parked capital instead of a wallet balance, and one on the 90 day term.
    function _openLoans(address self, uint256 key) internal {
        address borrowerD = vm.addr(BORROWER_D_KEY);

        // 5,000 USDG over 30 days on 60 NVDAx (10,584 USDG), or 47.2 percent LTV, from two lenders. The deployer
        // submits it as a relayer, so the hub verifies the borrower's signature on the request.
        LoanTypes.BorrowRequest memory request = _borrowRequest(borrowerD, 60e18, 5_000e6, 900, 30 days, 20);
        LoanTypes.LendOffer[] memory offers = new LoanTypes.LendOffer[](2);
        offers[0] = _lendOffer(self, 3_000e6, 825, 30 days, 20);
        offers[1] = _lendOffer(self, 2_000e6, 875, 30 days, 21);
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = _signOffer(key, offers[0]);
        signatures[1] = _signOffer(key, offers[1]);
        bytes memory requestSignature = _signBorrowRequest(BORROWER_D_KEY, request);

        vm.startBroadcast(key);
        relayedLoan = hub.originate(request, requestSignature, offers, signatures);

        // 10,000 USDG on 200 NVDAx, 28.3 percent LTV. The offer sets the park-idle flag, which makes the hub draw
        // the principal from the reserve adapter rather than from the lender directly.
        LoanTypes.LendOffer[] memory parkedOffer = new LoanTypes.LendOffer[](1);
        parkedOffer[0] = _flaggedOffer(self, 10_000e6, 800, 14 days, 22, LoanTypes.FLAG_PARK_IDLE);
        parkedLoan = _fill(self, key, 200e18, 10_000e6, 14 days, 21, parkedOffer);

        // 6,000 USDG over 90 days on 100 NVDAx, 34 percent LTV.
        longLoan = _fill(self, key, 100e18, 6_000e6, 90 days, 22, _oneOffer(self, 6_000e6, 875, 90 days, 23));
        vm.stopBroadcast();

        console2.log("Relayed loan", relayedLoan);
        console2.log("Loan funded from reserve", parkedLoan);
        console2.log("90-day loan", longLoan);
    }

    /// @dev Leaves loans in a spread of states: more collateral and a part payment on the loan Seed kept open, a
    ///      repayment from a third party, a repayment routed back into the vault, a slice sold to another
    ///      eligible lender, a request withdrawn before any fill, and two kinds of nonce cancellation.
    function _serviceLoans(address self, uint256 key) internal {
        vm.startBroadcast(key);
        hub.addCollateral(1, 15e18);
        hub.repay(1, 1_500e6);

        // The deployer is not the borrower on the relayed loan, but repayment is open to any payer.
        hub.repay(relayedLoan, 1_000e6);

        // Because this slice was funded from parked capital, what it receives is deposited back into the vault.
        hub.repay(parkedLoan, 500e6);

        // The slice note confirms the buyer holds a lender role and asks the hub to redirect future payments.
        slices.transferFrom(self, vm.addr(LENDER_E_KEY), hub.getLoan(longLoan).sliceIds[0]);

        // Withdrawing an unfilled request marks its digest as used, so a relayer can never submit it.
        hub.cancelRequest(_borrowRequest(self, 10e18, 1_000e6, 900, 7 days, 90));

        // Retire nonce 90 by itself, then all 256 nonces of word 1 in a single call.
        hub.cancel(90);
        hub.cancelWord(1, type(uint8).max);
        vm.stopBroadcast();
    }

    /// @dev Walks governance both ways: the guardian pauses and resumes, a backup credential issuer is added, one
    ///      operation is queued for SeedExecute and another is queued and then cancelled. The delay drops to a
    ///      minute so SeedExecute can follow shortly; the queued operation sets it back.
    function _exerciseGovernance(uint256 key) internal {
        bytes[] memory cancelledCalls = new bytes[](1);
        cancelledCalls[0] = abi.encodeCall(RiskConfig.setTermAllowed, (uint32(60 days), true));
        bytes32 cancelledSalt = keccak256("spatial.seed.sixtyDayTerm");

        vm.startBroadcast(key);
        riskConfig.setPaused(true, false);
        riskConfig.setPaused(false, false);
        riskConfig.setAttestationIssuer(vm.addr(BACKUP_ISSUER_KEY), true);

        riskConfig.setDelay(60);
        riskConfig.schedule(_capRaiseCalls(address(stock)), RAISE_SALT, RAISE_RATIONALE);

        riskConfig.schedule(cancelledCalls, cancelledSalt, keccak256("Add a 60 day term"));
        riskConfig.cancel(riskConfig.operationId(cancelledCalls, cancelledSalt));
        vm.stopBroadcast();

        bytes32 pendingId = riskConfig.operationId(_capRaiseCalls(address(stock)), RAISE_SALT);
        (uint64 readyAt,,,) = riskConfig.operations(pendingId);
        console2.log("Pending operation executable at", readyAt);
    }

    /// @dev Opens two loans right at the LTV limit and then cuts the price by 23.5 percent so both become
    ///      liquidatable. The first is sold off in three purchases while the market is open. For the second the
    ///      market is switched to closed: the lender who refused closed-market sales is split out, the lender who
    ///      wanted collateral is paid in kind, and the remainder is auctioned with the higher closed floor.
    function _runLiquidations(address self, uint256 key) internal {
        vm.startBroadcast(key);
        plainAuctionLoan =
            _fill(self, key, 200e18, 19_400e6, 7 days, 23, _oneOffer(self, 19_400e6, 900, 7 days, 24));

        LoanTypes.LendOffer[] memory mixed = new LoanTypes.LendOffer[](3);
        mixed[0] = _lendOffer(self, 12_000e6, 850, 30 days, 25);
        mixed[1] = _flaggedOffer(self, 9_000e6, 875, 30 days, 26, LoanTypes.FLAG_NO_CLOSED_MARKET_LIQUIDATION);
        mixed[2] = _flaggedOffer(self, 8_100e6, 900, 30 days, 27, LoanTypes.FLAG_SELF_LIQUIDATE);
        flaggedAuctionLoan = _fill(self, key, 300e18, 29_100e6, 30 days, 24, mixed);

        // At 135.00 each loan stands at 71.9 percent LTV, over the 70 percent trigger.
        priceFeed.set(PRICE_CRASH);

        auction.startAuction(plainAuctionLoan);
        auction.buy(plainAuctionLoan, 50e18, "");
        auction.buy(plainAuctionLoan, 50e18, "");
        // Ask for more than is left; the final purchase is cut so proceeds equal the debt plus the penalty.
        auction.buy(plainAuctionLoan, 200e18, "");

        stock.setMarketStatus(SESSION_CLOSED);
        auction.startAuction(flaggedAuctionLoan);
        splitLoan = hub.loanCount();
        auction.buy(flaggedAuctionLoan, 300e18, "");
        stock.setMarketStatus(SESSION_REGULAR);

        // Climb back to the opening price in two moves within the 25 percent cap, opening one more loan at the
        // midpoint so the guard records a checkpoint along the way.
        priceFeed.set(PRICE_RECOVER);
        _fill(self, key, 50e18, 3_000e6, 14 days, 25, _oneOffer(self, 3_000e6, 875, 14 days, 28));
        priceFeed.set(PRICE_OPEN);
        vm.stopBroadcast();
    }

    /// @dev Prints where everything ended up.
    function _logSummary(address self) internal view {
        console2.log("Total loans on the hub", hub.loanCount());
        console2.log("Total slices minted", hub.sliceCount());
        console2.log("Open-market auction loan status (5 = Settled)", uint8(hub.getLoan(plainAuctionLoan).status));
        console2.log("Closed-market auction loan status (5 = Settled)", uint8(hub.getLoan(flaggedAuctionLoan).status));
        console2.log("Loan carved out of it", splitLoan);
        console2.log("Carved-out loan status (1 = Active)", uint8(hub.getLoan(splitLoan).status));
        console2.log("Loan 1 health factor (wad)", hub.healthFactor(1));
        console2.log("Capital still in reserve", reserve.balanceOf(self));
        console2.log("Timelock delay now", riskConfig.delay());
    }

    // ---------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------

    /// @dev Builds a standard lend offer and sets the given flags on it. Flags are covered by the signature, so
    ///      they must be in place before `_signOffer` runs.
    function _flaggedOffer(address maker, uint256 principalMax, uint16 aprBps, uint32 term, uint256 nonce, uint8 flags)
        internal
        view
        returns (LoanTypes.LendOffer memory offer)
    {
        offer = _lendOffer(maker, principalMax, aprBps, term, nonce);
        offer.flags = flags;
    }

    /// @dev Signs a borrow request as the borrower so a relayer can submit it; returns r, s, v packed.
    function _signBorrowRequest(uint256 key, LoanTypes.BorrowRequest memory request)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                QuoteHash.BORROW_REQUEST_TYPEHASH,
                request.borrower,
                request.collateralToken,
                request.loanToken,
                request.collateralAmount,
                request.principal,
                request.maxAprBps,
                request.termSeconds,
                request.fillDeadline,
                request.salt
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", hub.domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }
}
