// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {QueuedRaise} from "./SeedDeep.s.sol";
import {RiskConfig} from "../src/RiskConfig.sol";

/// @title SeedExecute
/// @notice Carries out the operation SeedDeep put in the queue, raising the collateral token's exposure cap and
///         restoring a one hour timelock delay. It only goes through once SeedDeep's shortened delay has run
///         out, so running both in turn takes a governance change from proposal to execution, emitting an event
///         at each stage.
/// @dev Execution needs exactly the calls and salt that were scheduled, so both come from QueuedRaise. Start it
///      roughly a minute after SeedDeep finishes. Example:
///        forge script script/SeedExecute.s.sol --slow --broadcast --rpc-url robinhood_testnet --gas-estimate-multiplier 200
contract SeedExecute is Script, QueuedRaise {
    function run() external {
        uint256 key = vm.envUint("PRIVATE_KEY");

        string memory json = vm.readFile(string.concat("deployments/", vm.toString(block.chainid), ".json"));
        RiskConfig riskConfig = RiskConfig(vm.parseJsonAddress(json, ".RiskConfig"));
        address stockToken = vm.parseJsonAddress(json, ".StockToken");

        vm.startBroadcast(key);
        riskConfig.execute(_capRaiseCalls(stockToken), RAISE_SALT);
        vm.stopBroadcast();

        console2.log("Exposure cap now", riskConfig.tokenConfig(stockToken).exposureCap);
        console2.log("Timelock delay now", riskConfig.delay());
    }
}
