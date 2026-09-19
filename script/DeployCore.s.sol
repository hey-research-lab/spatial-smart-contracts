// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {RiskConfig} from "../src/RiskConfig.sol";
import {IRiskConfig} from "../src/interfaces/IRiskConfig.sol";
import {PermissionRegistry} from "../src/PermissionRegistry.sol";
import {CredentialRegistry} from "../src/adapters/CredentialRegistry.sol";
import {OracleGuard} from "../src/OracleGuard.sol";
import {SliceNote} from "../src/SliceNote.sol";
import {CreditHub} from "../src/CreditHub.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
import {IReserveAdapter} from "../src/interfaces/IReserveAdapter.sol";
import {AggregatorV3Interface} from "../src/interfaces/IExternal.sol";
import {Permissions} from "../src/libraries/LoanTypes.sol";
import {MockERC20, MockStockToken, MockAggregatorV3} from "../src/mocks/Mocks.sol";

/// @title DeployCore
/// @notice A trimmed deployment meant for testnets and local nodes. It brings up the risk config, the hub and
///         the liquidation auction together with their hard dependencies (the permission registry and the
///         credential registry for roles, the guard for prices and the slice note for lender positions), and
///         mocks USDG, a single stock token and that token's Chainlink feed. The rollover market, the reserve
///         adapter, the fee vault and the ERC-4626 vault are omitted, so protocol fees go to the deployer.
/// @dev Reads PRIVATE_KEY (one wallet acts as deployer, owner, guardian and credential issuer) and
///      TIMELOCK_DELAY (in seconds, 3600 if unset). Refuses to run on chain 4663. It writes
///      `deployments/<chainId>.json` with the same set of keys as Deploy.s.sol, filling the omitted contracts
///      with the zero address. Example:
///        forge script script/DeployCore.s.sol --rpc-url robinhood_testnet --broadcast
contract DeployCore is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        uint256 timelockDelay = vm.envOr("TIMELOCK_DELAY", uint256(1 hours));
        require(block.chainid != 4663, "core-only deploy is for testnet");

        vm.startBroadcast(deployerKey);

        // Stand-ins for the external tokens and the price feed.
        MockERC20 usdg = new MockERC20("Global Dollar (mock)", "USDG", 6);
        MockStockToken stock = new MockStockToken("NVIDIA Stock Token (mock)", "NVDAx");
        MockAggregatorV3 priceFeed = new MockAggregatorV3(8, 176_40_000_000);

        // Protocol contracts; the deployer doubles as owner, guardian and fee recipient.
        RiskConfig riskConfig = new RiskConfig(deployer, deployer, timelockDelay);
        PermissionRegistry permissions = new PermissionRegistry(riskConfig);
        CredentialRegistry credentials = new CredentialRegistry(riskConfig);
        OracleGuard guard = new OracleGuard(riskConfig);
        SliceNote slices = new SliceNote(permissions, riskConfig);
        CreditHub hub = new CreditHub(riskConfig, permissions, guard, slices, deployer);
        LiquidationAuction auction = new LiquidationAuction(hub, riskConfig, permissions, guard);

        // Opening risk settings. Bootstrap mode lets the owner write them immediately.
        riskConfig.setEligibilityAdapter(address(credentials));
        riskConfig.setAttestationIssuer(deployer, true);
        riskConfig.setTierConfig(
            1, IRiskConfig.TierConfig({maxLtvBps: 5500, liqLtvBps: 7000, closedHaircutBps: 1000, enabled: true})
        );
        riskConfig.setTokenConfig(
            address(stock), IRiskConfig.TokenConfig({tier: 1, exposureCap: 1_000_000e6, enabled: true})
        );
        riskConfig.setLoanTokenEnabled(address(usdg), true);
        riskConfig.setTermAllowed(7 days, true);
        riskConfig.setTermAllowed(14 days, true);
        riskConfig.setTermAllowed(30 days, true);
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
        riskConfig.setFeeParams(
            IRiskConfig.FeeParams({
                originationBps: 25, interestShareBps: 1000, refinanceBps: 10, idleYieldShareBps: 500
            })
        );

        // A single feed for the guard. The mock stock token reports its own session, pause flag and multiplier.
        guard.configureFeed(
            address(stock),
            address(usdg),
            AggregatorV3Interface(address(priceFeed)),
            1 hours,
            2 hours,
            4 days,
            2500,
            1 hours,
            200,
            address(stock),
            address(stock),
            address(stock),
            address(0)
        );

        // Hook the hub up to the slice notes and the auction. The rollover and reserve slots stay empty.
        slices.setDesk(address(hub));
        hub.wire(address(auction), address(0), IReserveAdapter(address(0)));

        // Credential the deployer as borrower, professional lender and liquidator, which the seed scripts expect.
        uint64 validUntil = uint64(block.timestamp + 365 days);
        credentials.attest(deployer, Permissions.BORROWER, "LT", 2, validUntil);
        credentials.attest(deployer, Permissions.LENDER_PROFESSIONAL, "LT", 3, validUntil);
        credentials.attest(deployer, Permissions.LIQUIDATOR, "LT", 3, validUntil);

        vm.stopBroadcast();

        string memory key = "spatial";
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeAddress(key, "RiskConfig", address(riskConfig));
        vm.serializeAddress(key, "PermissionRegistry", address(permissions));
        vm.serializeAddress(key, "CredentialRegistry", address(credentials));
        vm.serializeAddress(key, "OracleGuard", address(guard));
        vm.serializeAddress(key, "SliceNote", address(slices));
        vm.serializeAddress(key, "FeeVault", address(0));
        vm.serializeAddress(key, "CreditHub", address(hub));
        vm.serializeAddress(key, "LiquidationAuction", address(auction));
        vm.serializeAddress(key, "RolloverMarket", address(0));
        vm.serializeAddress(key, "ReserveAdapter", address(0));
        vm.serializeAddress(key, "USDG", address(usdg));
        vm.serializeAddress(key, "StockToken", address(stock));
        vm.serializeAddress(key, "StockFeed", address(priceFeed));
        string memory json = vm.serializeAddress(key, "Vault", address(0));
        string memory file = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(json, file);
        console2.log("Deployment file saved:", file);
        console2.log("RiskConfig", address(riskConfig));
        console2.log("CreditHub", address(hub));
        console2.log("LiquidationAuction", address(auction));
    }
}
