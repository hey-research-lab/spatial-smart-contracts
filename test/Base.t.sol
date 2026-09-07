// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {RiskConfig} from "../src/RiskConfig.sol";
import {IRiskConfig} from "../src/interfaces/IRiskConfig.sol";
import {PermissionRegistry} from "../src/PermissionRegistry.sol";
import {CredentialRegistry} from "../src/adapters/CredentialRegistry.sol";
import {OracleGuard} from "../src/OracleGuard.sol";
import {SliceNote} from "../src/SliceNote.sol";
import {FeeVault} from "../src/FeeVault.sol";
import {CreditHub} from "../src/CreditHub.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
import {RolloverMarket} from "../src/RolloverMarket.sol";
import {ReserveAdapter} from "../src/ReserveAdapter.sol";
import {AggregatorV3Interface} from "../src/interfaces/IExternal.sol";
import {LoanTypes, Permissions} from "../src/libraries/LoanTypes.sol";
import {MockERC20, MockStockToken, MockAggregatorV3, MockVault4626, MockStreamAdapter} from "../src/mocks/Mocks.sol";

/// @title BaseTest
/// @notice Shared starting point for the test suites. It stands up every Spatial contract on top of mock
///         tokens, mock price feeds and a mock ERC-4626 vault, loads the live parameter set, issues credentials
///         to a borrower, three professional lenders and a liquidator, and gives each of them a balance. Suites
///         extend it and layer their own cases on top.
abstract contract BaseTest is Test {
    uint256 internal constant NVDA_PRICE_8 = 176_40_000_000; // 176.40 USDG per NVDA, quoted with 8 decimals
    uint32 internal constant TERM_30D = 30 days;

    address internal gov = makeAddr("gov");
    address internal guardian = makeAddr("guardian");
    address internal issuer = makeAddr("issuer");
    address internal keeper = makeAddr("keeper");
    address internal liquidator = makeAddr("liquidator");

    uint256 internal borrowerPk = 0xB0B;
    uint256 internal lender1Pk = 0xA11CE;
    uint256 internal lender2Pk = 0xA12CE;
    uint256 internal lender3Pk = 0xA13CE;
    address internal borrower = vm.addr(borrowerPk);
    address internal lender1 = vm.addr(lender1Pk);
    address internal lender2 = vm.addr(lender2Pk);
    address internal lender3 = vm.addr(lender3Pk);

    RiskConfig internal riskConfig;
    PermissionRegistry internal permissions;
    CredentialRegistry internal credentials;
    OracleGuard internal guard;
    SliceNote internal sliceNote;
    FeeVault internal feeVault;
    CreditHub internal hub;
    LiquidationAuction internal auction;
    RolloverMarket internal rollover;
    ReserveAdapter internal idle;

    MockERC20 internal usdg;
    MockStockToken internal nvda;
    MockAggregatorV3 internal nvdaFeed;
    MockAggregatorV3 internal sequencer;
    MockVault4626 internal vault;
    MockStreamAdapter internal stream;

    function setUp() public virtual {
        // Pin the clock to 16:00 UTC on a Wednesday. Market hours come from the mock token here, so the guard
        // never falls back to its own calendar logic. Pinning a weekday afternoon anyway makes maturities, expiries
        // and hand-worked numbers repeatable, and it would count as an open session if that fallback ever ran.
        vm.warp(1_790_000_000 + 2 days + 16 hours - (1_790_000_000 % 1 days));
        _deploy();
        _configure();
        _fund();
    }

    function _deploy() internal {
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        nvda = new MockStockToken("NVIDIA Stock Token", "NVDAx");
        nvdaFeed = new MockAggregatorV3(8, int256(NVDA_PRICE_8));
        sequencer = new MockAggregatorV3(0, 0);
        vault = new MockVault4626(usdg);
        stream = new MockStreamAdapter();

        riskConfig = new RiskConfig(gov, guardian, 1 days);
        permissions = new PermissionRegistry(riskConfig);
        credentials = new CredentialRegistry(riskConfig);
        guard = new OracleGuard(riskConfig);
        sliceNote = new SliceNote(permissions, riskConfig);
        feeVault = new FeeVault(riskConfig);
        hub = new CreditHub(riskConfig, permissions, guard, sliceNote, address(feeVault));
        auction = new LiquidationAuction(hub, riskConfig, permissions, guard);
        rollover = new RolloverMarket(hub, riskConfig, permissions);
    }

    function _configure() internal {
        vm.startPrank(gov);
        riskConfig.setEligibilityAdapter(address(credentials));
        riskConfig.setAttestationIssuer(issuer, true);
        riskConfig.setTierConfig(
            1, IRiskConfig.TierConfig({maxLtvBps: 5500, liqLtvBps: 7000, closedHaircutBps: 1000, enabled: true})
        );
        riskConfig.setTierConfig(
            2, IRiskConfig.TierConfig({maxLtvBps: 4500, liqLtvBps: 6000, closedHaircutBps: 1000, enabled: true})
        );
        riskConfig.setTokenConfig(
            address(nvda), IRiskConfig.TokenConfig({tier: 1, exposureCap: 10_000_000e6, enabled: true})
        );
        riskConfig.setLoanTokenEnabled(address(usdg), true);
        riskConfig.setTermAllowed(7 days, true);
        riskConfig.setTermAllowed(14 days, true);
        riskConfig.setTermAllowed(30 days, true);
        riskConfig.setTermAllowed(90 days, true);
        riskConfig.setLoanParams(
            IRiskConfig.LoanParams({
                minInterestPeriod: 3 days, graceWindow: 24 hours, sequencerGrace: 1 hours, maxSlicesPerLoan: 32
            })
        );
        riskConfig.setAuctionParams(
            IRiskConfig.AuctionParams({
                startPremiumBps: 300,
                floorBpsRegular: 7000,
                floorBpsClosed: 8500,
                duration: 45 minutes,
                penaltyBps: 300,
                keeperShareBps: 3334,
                lenderPenaltyShareBps: 5000
            })
        );
        riskConfig.setRefinanceParams(IRiskConfig.RefinanceParams({capSpreadBps: 400, duration: 4 hours}));
        riskConfig.setFeeParams(
            IRiskConfig.FeeParams({
                originationBps: 25, interestShareBps: 1000, refinanceBps: 10, idleYieldShareBps: 500
            })
        );
        riskConfig.setVaultWhitelisted(address(vault), true);

        guard.configureFeed(
            address(nvda),
            address(usdg),
            AggregatorV3Interface(address(nvdaFeed)),
            1 hours,
            2 hours,
            4 days,
            2500,
            1 hours,
            200,
            address(nvda),
            address(nvda),
            address(nvda),
            address(0)
        );
        guard.setSequencerFeed(AggregatorV3Interface(address(sequencer)));

        idle = new ReserveAdapter(riskConfig, IERC4626(address(vault)));
        sliceNote.setDesk(address(hub));
        idle.setDesk(address(hub));
        hub.wire(address(auction), address(rollover), idle);
        vm.stopPrank();

        // Credentials for every participant, matching the roles the hub and auction look for.
        vm.startPrank(issuer);
        credentials.attest(borrower, Permissions.BORROWER, "LT", 2, uint64(block.timestamp + 365 days));
        credentials.attest(lender1, Permissions.LENDER_PROFESSIONAL, "LT", 3, uint64(block.timestamp + 365 days));
        credentials.attest(lender2, Permissions.LENDER_PROFESSIONAL, "DE", 3, uint64(block.timestamp + 365 days));
        credentials.attest(lender3, Permissions.LENDER_PROFESSIONAL, "IE", 3, uint64(block.timestamp + 365 days));
        credentials.attest(liquidator, Permissions.LIQUIDATOR, "LT", 3, uint64(block.timestamp + 365 days));
        vm.stopPrank();

        // Report a sequencer that has been running for a week. With that history the hour-long restart grace is
        // already over, and only a test that rewrites the feed will hit it.
        sequencer.setWithTimestamps(0, block.timestamp - 7 days, block.timestamp);
    }

    function _fund() internal {
        nvda.mint(borrower, 1_000e18);
        usdg.mint(borrower, 100_000e6);
        usdg.mint(lender1, 1_000_000e6);
        usdg.mint(lender2, 1_000_000e6);
        usdg.mint(lender3, 1_000_000e6);
        usdg.mint(liquidator, 10_000_000e6);

        vm.prank(borrower);
        nvda.approve(address(hub), type(uint256).max);
        vm.prank(borrower);
        usdg.approve(address(hub), type(uint256).max);
        vm.prank(lender1);
        usdg.approve(address(hub), type(uint256).max);
        vm.prank(lender2);
        usdg.approve(address(hub), type(uint256).max);
        vm.prank(lender3);
        usdg.approve(address(hub), type(uint256).max);
        vm.prank(lender1);
        usdg.approve(address(rollover), type(uint256).max);
        vm.prank(lender2);
        usdg.approve(address(rollover), type(uint256).max);
        vm.prank(lender3);
        usdg.approve(address(rollover), type(uint256).max);
        vm.prank(liquidator);
        usdg.approve(address(auction), type(uint256).max);
    }

    /* ==================== Builders for offers, requests and loans ==================== */

    /// @dev Builds a lend offer using the standard values: NVDA collateral, USDG loans, a 1,000 USDG floor, a
    ///      5,500 bps LTV ceiling, 30 days to maturity, a week until it lapses, and a salt hashed from the maker
    ///      and nonce.
    function _offer(address maker, uint256 principalMax, uint16 aprBps, uint256 nonce, uint8 flags)
        internal
        view
        returns (LoanTypes.LendOffer memory o)
    {
        o = LoanTypes.LendOffer({
            maker: maker,
            side: LoanTypes.Side.Lend,
            collateralToken: address(nvda),
            loanToken: address(usdg),
            principalMin: 1_000e6,
            principalMax: principalMax,
            aprBps: aprBps,
            maxLtvBps: 5500,
            termSeconds: TERM_30D,
            expiry: uint40(block.timestamp + 7 days),
            nonce: nonce,
            salt: keccak256(abi.encode(maker, nonce)),
            requestId: bytes32(0),
            flags: flags
        });
    }

    function _sign(uint256 pk, LoanTypes.LendOffer memory o) internal view returns (bytes memory) {
        bytes32 digest = _offerDigest(o);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Computes the EIP-712 digest independently of QuoteHash, spelling out the type string in full. Should
    ///      the library ever disagree with the layout wallets sign, signatures produced in these tests would fail.
    function _offerDigest(LoanTypes.LendOffer memory o) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "LendOffer(address maker,uint8 side,address collateralToken,address loanToken,uint256 principalMin,"
                    "uint256 principalMax,uint16 aprBps,uint16 maxLtvBps,uint32 termSeconds,uint40 expiry,uint256 nonce,"
                    "bytes32 salt,bytes32 requestId,uint8 flags)"
                ),
                o.maker,
                uint8(o.side),
                o.collateralToken,
                o.loanToken,
                o.principalMin,
                o.principalMax,
                o.aprBps,
                o.maxLtvBps,
                o.termSeconds,
                o.expiry,
                o.nonce,
                o.salt,
                o.requestId,
                o.flags
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", hub.domainSeparator(), structHash));
    }

    /// @dev Builds a 30-day borrow request for the standard borrower that must be filled within a day, salted
    ///      with the value 1.
    function _request(uint256 collateral, uint256 principal, uint16 maxApr)
        internal
        view
        returns (LoanTypes.BorrowRequest memory)
    {
        return LoanTypes.BorrowRequest({
            borrower: borrower,
            collateralToken: address(nvda),
            loanToken: address(usdg),
            collateralAmount: collateral,
            principal: principal,
            maxAprBps: maxApr,
            termSeconds: TERM_30D,
            fillDeadline: uint40(block.timestamp + 1 days),
            salt: bytes32(uint256(1))
        });
    }

    /// @dev Opens the standard loan used across the suites. 250 NVDA, worth 44,100 USDG at the starting price,
    ///      secures 20,000 USDG for 30 days, funded by three lenders at 850, 890 and 900 bps.
    function _originateExample() internal returns (uint256 loanId) {
        LoanTypes.LendOffer[] memory offers = new LoanTypes.LendOffer[](3);
        bytes[] memory sigs = new bytes[](3);
        offers[0] = _offer(lender1, 5_000e6, 850, 1, 0);
        offers[1] = _offer(lender2, 10_000e6, 890, 1, 0);
        offers[2] = _offer(lender3, 5_000e6, 900, 1, 0);
        sigs[0] = _sign(lender1Pk, offers[0]);
        sigs[1] = _sign(lender2Pk, offers[1]);
        sigs[2] = _sign(lender3Pk, offers[2]);
        vm.prank(borrower);
        loanId = hub.originate(_request(250e18, 20_000e6, 900), "", offers, sigs);
    }

    /// @dev Pushes a fresh NVDA price (8 decimals) to the mock feed, timestamped with the current block.
    function _setPrice(uint256 price8) internal {
        nvdaFeed.set(int256(price8));
    }
}
