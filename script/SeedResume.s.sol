// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";
import {SeedCore} from "./SeedCore.s.sol";

/// @title SeedResume
/// @notice Picks up a SeedCore run that stopped right after the auction on loan 3 began. It completes the
///         purchase, returns the price to its opening level in two cap-respecting moves, opens loan 4 and
///         cancels nonce 6, which is everything SeedCore would have done next.
/// @dev Loan 3 must still have a live auction. Once its 45 minute window has passed, `restart` it before
///      running this.
contract SeedResume is SeedCore {
    function run() external override {
        uint256 key = vm.envUint("PRIVATE_KEY");
        address self = vm.addr(key);
        _readCoreAddresses();

        uint256 loan3 = 3;
        vm.startBroadcast(key);

        auction.buy(loan3, 250e18, "");
        console2.log("Auction cleared on loan", loan3);

        priceFeed.set(PRICE_RECOVER);
        uint256 loan4 = _fill(self, key, 50e18, 3_000e6, 14 days, 4, _oneOffer(self, 3_000e6, 875, 14 days, 5));
        console2.log("Loan 4 opened", loan4);
        priceFeed.set(PRICE_OPEN);

        hub.cancel(6);

        vm.stopBroadcast();

        console2.log("Loan 3 status (5 = Settled)", uint8(hub.getLoan(loan3).status));
        console2.log("Loan 4 health factor (wad)", hub.healthFactor(loan4));
    }
}
