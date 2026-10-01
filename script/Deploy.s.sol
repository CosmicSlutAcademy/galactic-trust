// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {GalacticTrust} from "../src/GalacticTrust.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

contract Deploy is Script {
    function run() external returns (GalacticTrust glt, TimelockController timelock) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address treasury = vm.envAddress("TREASURY");
        uint256 initialSupply = vm.envUint("INITIAL_SUPPLY");

        uint256 minDelay = vm.envUint("TIMELOCK_DELAY");
        address[] memory proposers = new address[](1);
        proposers[0] = msg.sender;
        address[] memory executors = new address[](1);
        executors[0] = address(0);

        vm.startBroadcast(pk);
        timelock = new TimelockController(minDelay, proposers, executors, address(0));
        glt = new GalacticTrust(address(timelock), 1_000e18, address(0), initialSupply, treasury);

        // The contract now defaults both bond amounts to a non-zero value, because a zero
        // bond makes signing and challenging free and reinstates the griefing vectors the
        // bonds exist to close. Deploys can still tune them through the timelock.
        vm.stopBroadcast();
    }
}
