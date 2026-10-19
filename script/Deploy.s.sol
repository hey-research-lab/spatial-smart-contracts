// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
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
import {Permissions} from "../src/libraries/LoanTypes.sol";
import {MockERC20, MockStockToken, MockAggregatorV3, MockVault4626} from "../src/mocks/Mocks.sol";

/// @title Deploy
/// @notice Stands up every Spatial contract on Robinhood Chain (mainnet 4663 or testnet 46630). It creates the
///         contracts, writes the initial risk settings, points the guard at the collateral feed, connects the
///         pieces together and saves the resulting addresses to `deployments/<chainId>.json`.
/// @dev Settings come from the environment:
///        PRIVATE_KEY             key of the deploying wallet, which owns the risk config until GOV is handed it
///        GOV                     final owner of the risk config (falls back to the deployer). Ownership moves in
///                                two steps, so GOV has to call `acceptOwnership()` once this has run
///        GUARDIAN                address allowed to pause (falls back to the deployer)
///        TIMELOCK_DELAY          governance delay on the risk config, in seconds (falls back to 3600)
///        DEPLOY_MOCKS            "true" allows mock stand-ins for any external address not supplied
///                                (on by default, except on chain 4663)
///        FINISH_BOOTSTRAP        "true" calls `finishBootstrap()`, so later edits must wait out the timelock
///        ATTESTATION_ISSUER      address allowed to issue credentials (falls back to the deployer)
///        USDG                    loan currency; a mock is deployed if unset and mocks are allowed
///        STOCK_TOKEN, STOCK_FEED tier 1 collateral token and its Chainlink price feed; mocked if unset and allowed
///        VAULT                   ERC-4626 vault that holds idle lender funds; mocked if unset and allowed
///        SEQUENCER_FEED          Chainlink L2 sequencer uptime feed; skipped if unset
///        MARKET_STATUS_SOURCE    source of trading-session data for the guard; unused when mocks are on, and if
///                                unset the guard relies on its built-in weekly timetable
///        STREAM_ADAPTER          Data Streams adapter for the collateral; unset means Data Feeds alone
///        STALENESS_REGULAR, STALENESS_EXTENDED, STALENESS_CLOSED
///                                maximum price age per session, in seconds (3600, 7200 and 345600 if unset)
///        MOVE_CAP_WINDOW         length in seconds of the checkpoint window behind the 25 percent move cap
///                                (3600 if unset)
///      Example:
///        forge script script/Deploy.s.sol --rpc-url robinhood_testnet --broadcast --verify
contract Deploy is Script {
    /// @dev Everything that ends up in the deployment file.
    struct Deployed {
        address riskConfig;
        address permissionRegistry;
        address credentialRegistry;
        address oracleGuard;
        address sliceNote;
        address feeVault;
        address creditHub;
        address liquidationAuction;
        address rolloverMarket;
        address reserveAdapter;
        address usdg;
        address stockToken;
        address stockFeed;
        address vault;
    }

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address owner = vm.envOr("GOV", deployer);
        address guardian = vm.envOr("GUARDIAN", deployer);
        uint256 timelockDelay = vm.envOr("TIMELOCK_DELAY", uint256(1 hours));
        bool allowMocks = vm.envOr("DEPLOY_MOCKS", block.chainid != 4663);
        bool lockBootstrap = vm.envOr("FINISH_BOOTSTRAP", false);
        address issuer = vm.envOr("ATTESTATION_ISSUER", deployer);

        Deployed memory out;
        vm.startBroadcast(deployerKey);

        address sequencerFeed = _externals(out, allowMocks);

        // Core contracts. The deployer keeps ownership of the risk config while it is being filled in and only
        // passes it on at the very end.
        RiskConfig riskConfig = new RiskConfig(deployer, guardian, timelockDelay);
        PermissionRegistry permissions = new PermissionRegistry(riskConfig);
        CredentialRegistry credentials = new CredentialRegistry(riskConfig);
        OracleGuard guard = new OracleGuard(riskConfig);
        SliceNote slices = new SliceNote(permissions, riskConfig);
        FeeVault feeVault = new FeeVault(riskConfig);
        CreditHub hub = new CreditHub(riskConfig, permissions, guard, slices, address(feeVault));
        LiquidationAuction liquidationAuction = new LiquidationAuction(hub, riskConfig, permissions, guard);
        RolloverMarket rolloverMarket = new RolloverMarket(hub, riskConfig, permissions);

        _writeRiskSettings(riskConfig, address(credentials), issuer, out);
        _configureGuard(guard, out, allowMocks, sequencerFeed);

        // Connect the hub to the slice notes, the auctions and the reserve adapter.
        ReserveAdapter reserve = new ReserveAdapter(riskConfig, IERC4626(out.vault));
        slices.setDesk(address(hub));
        reserve.setDesk(address(hub));
        hub.wire(address(liquidationAuction), address(rolloverMarket), reserve);

        // On a mock deployment where the deployer also issues credentials, give it the roles that the seed
        // scripts need so it can act as every participant.
        if (allowMocks && issuer == deployer) {
            uint64 validUntil = uint64(block.timestamp + 365 days);
            credentials.attest(deployer, Permissions.BORROWER, "LT", 2, validUntil);
            credentials.attest(deployer, Permissions.LENDER_PROFESSIONAL, "LT", 3, validUntil);
            credentials.attest(deployer, Permissions.LIQUIDATOR, "LT", 3, validUntil);
            credentials.attest(deployer, Permissions.RELAYER, "LT", 0, validUntil);
        }

        if (lockBootstrap) riskConfig.finishBootstrap();
        if (owner != deployer) riskConfig.transferOwnership(owner);

        vm.stopBroadcast();

        out.riskConfig = address(riskConfig);
        out.permissionRegistry = address(permissions);
        out.credentialRegistry = address(credentials);
        out.oracleGuard = address(guard);
        out.sliceNote = address(slices);
        out.feeVault = address(feeVault);
        out.creditHub = address(hub);
        out.liquidationAuction = address(liquidationAuction);
        out.rolloverMarket = address(rolloverMarket);
        out.reserveAdapter = address(reserve);
        _save(out);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Steps
    // ---------------------------------------------------------------------------------------------------------

    /// @dev Takes the third-party addresses from the environment and deploys a mock for each one that is
    ///      missing, provided mocks are allowed on this chain. Returns the optional sequencer feed.
    function _externals(Deployed memory out, bool allowMocks) internal returns (address sequencerFeed) {
        out.usdg = vm.envOr("USDG", address(0));
        out.stockToken = vm.envOr("STOCK_TOKEN", address(0));
        out.stockFeed = vm.envOr("STOCK_FEED", address(0));
        out.vault = vm.envOr("VAULT", address(0));
        sequencerFeed = vm.envOr("SEQUENCER_FEED", address(0));

        if (out.usdg == address(0)) {
            require(allowMocks, "USDG required");
            out.usdg = address(new MockERC20("Global Dollar (mock)", "USDG", 6));
        }
        if (out.stockToken == address(0)) {
            require(allowMocks, "STOCK_TOKEN required");
            out.stockToken = address(new MockStockToken("NVIDIA Stock Token (mock)", "NVDAx"));
        }
        if (out.stockFeed == address(0)) {
            require(allowMocks, "STOCK_FEED required");
            out.stockFeed = address(new MockAggregatorV3(8, 176_40_000_000));
        }
        if (out.vault == address(0)) {
            require(allowMocks, "VAULT required");
            out.vault = address(new MockVault4626(MockERC20(out.usdg)));
        }
    }

    /// @dev Fills in the opening risk settings. Bootstrap mode is still on at this point, so the owner can write
    ///      each value straight away without queuing it.
    function _writeRiskSettings(RiskConfig riskConfig, address credentials, address issuer, Deployed memory out)
        internal
    {
        riskConfig.setEligibilityAdapter(credentials);
        riskConfig.setAttestationIssuer(issuer, true);
        riskConfig.setTierConfig(
            1, IRiskConfig.TierConfig({maxLtvBps: 5500, liqLtvBps: 7000, closedHaircutBps: 1000, enabled: true})
        );
        riskConfig.setTierConfig(
            2, IRiskConfig.TierConfig({maxLtvBps: 4500, liqLtvBps: 6000, closedHaircutBps: 1000, enabled: true})
        );
        riskConfig.setTierConfig(
            3, IRiskConfig.TierConfig({maxLtvBps: 3000, liqLtvBps: 4500, closedHaircutBps: 1500, enabled: true})
        );
        riskConfig.setTokenConfig(
            out.stockToken, IRiskConfig.TokenConfig({tier: 1, exposureCap: 1_000_000e6, enabled: true})
        );
        riskConfig.setLoanTokenEnabled(out.usdg, true);
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
        riskConfig.setVaultWhitelisted(out.vault, true);
    }

    /// @dev Registers the collateral feed with the guard. Pause state and the ERC-8056 multiplier are read from
    ///      the stock token. The session status also comes from the token when mocks are on, and otherwise from
    ///      MARKET_STATUS_SOURCE.
    function _configureGuard(OracleGuard guard, Deployed memory out, bool allowMocks, address sequencerFeed)
        internal
    {
        address sessionSource = allowMocks ? out.stockToken : vm.envOr("MARKET_STATUS_SOURCE", address(0));
        guard.configureFeed(
            out.stockToken,
            out.usdg,
            AggregatorV3Interface(out.stockFeed),
            uint32(vm.envOr("STALENESS_REGULAR", uint256(1 hours))),
            uint32(vm.envOr("STALENESS_EXTENDED", uint256(2 hours))),
            uint32(vm.envOr("STALENESS_CLOSED", uint256(4 days))),
            2500,
            uint32(vm.envOr("MOVE_CAP_WINDOW", uint256(1 hours))),
            200,
            sessionSource,
            out.stockToken,
            out.stockToken,
            vm.envOr("STREAM_ADAPTER", address(0))
        );
        if (sequencerFeed != address(0)) guard.setSequencerFeed(AggregatorV3Interface(sequencerFeed));
    }

    /// @dev Serialises the address set, keyed by contract name, into the per-chain deployment file.
    function _save(Deployed memory out) internal {
        string memory key = "spatial";
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeAddress(key, "RiskConfig", out.riskConfig);
        vm.serializeAddress(key, "PermissionRegistry", out.permissionRegistry);
        vm.serializeAddress(key, "CredentialRegistry", out.credentialRegistry);
        vm.serializeAddress(key, "OracleGuard", out.oracleGuard);
        vm.serializeAddress(key, "SliceNote", out.sliceNote);
        vm.serializeAddress(key, "FeeVault", out.feeVault);
        vm.serializeAddress(key, "CreditHub", out.creditHub);
        vm.serializeAddress(key, "LiquidationAuction", out.liquidationAuction);
        vm.serializeAddress(key, "RolloverMarket", out.rolloverMarket);
        vm.serializeAddress(key, "ReserveAdapter", out.reserveAdapter);
        vm.serializeAddress(key, "USDG", out.usdg);
        vm.serializeAddress(key, "StockToken", out.stockToken);
        vm.serializeAddress(key, "StockFeed", out.stockFeed);
        string memory json = vm.serializeAddress(key, "Vault", out.vault);
        string memory file = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.createDir("deployments", true);
        vm.writeJson(json, file);
        console2.log("Deployment file saved:", file);
        console2.log("CreditHub", out.creditHub);
    }
}
