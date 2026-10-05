// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {GalacticTrust} from "../src/GalacticTrust.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

contract Deploy is Script {
    /// @dev Everything this script does not receive from the environment. Every value that
    /// silently defaults is a value nobody reads, and on a deployment the parameter *is* the
    /// product: `minStake` sets the price of an attestation, `TIMELOCK_DELAY` sets how fast the
    /// owner can move.
    uint256 internal constant DEFAULT_MIN_STAKE = 1_000e18;
    uint256 internal constant DEFAULT_TIMELOCK_DELAY = 2 days;

    function run() external returns (GalacticTrust glt, TimelockController timelock) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address treasury = vm.envAddress("TREASURY");
        uint256 initialSupply = vm.envUint("INITIAL_SUPPLY");
        address verifier = vm.envOr("VERIFIER", address(0));

        // `vm.envOr`, not `vm.envUint`: a missing key reverts, and every run command written
        // before these existed would fail on a variable the script no longer needs. Optional
        // means optional. The defaults are stated rather than implied, and printed on deploy.
        uint256 minDelay = vm.envOr("TIMELOCK_DELAY", DEFAULT_TIMELOCK_DELAY);
        uint256 minStake = vm.envOr("MIN_STAKE", DEFAULT_MIN_STAKE);

        address deployer = vm.addr(pk);

        // The timelock is the owner, and it is constructed with `admin = address(0)`. With an
        // admin set, that key can re-point the timelock's own proposer and executor sets at any
        // moment, which silently restores single-key control over everything the timelock
        // governs -- including `transferOwnership` of GLT itself.
        address[] memory proposers = new address[](1);
        proposers[0] = deployer;
        address[] memory executors = new address[](1);
        executors[0] = address(0); // open execution: the delay is the control, not the executor set

        vm.startBroadcast(pk);
        timelock = new TimelockController(minDelay, proposers, executors, address(0));
        glt = new GalacticTrust(address(timelock), minStake, verifier, initialSupply, treasury);

        // Both bond amounts default non-zero, because a zero bond makes signing and challenging
        // free and reinstates the griefing vectors the bonds exist to close. Deploys can tune
        // them through the timelock.
        vm.stopBroadcast();

        console.log("GLT            ", address(glt));
        console.log("owner          ", glt.owner());
        console.log("timelock       ", address(timelock));
        console.log("minDelay       ", minDelay);
        console.log("minStake       ", minStake);
        console.log("treasury       ", treasury);
        console.log("initialSupply  ", initialSupply);
        console.log("verifier       ", verifier);

        // Deliberately NOT registering a curator here. An earlier version tried to, and
        // deploying against a live node is what proved it cannot work: `registerCurator` is
        // `onlyOwner` and the owner is the timelock, so the call reverts
        // `OwnableUnauthorizedAccount` for any deployer. There is no inline path to it, and
        // scheduling one would leave the deployer holding an unexecuted operation whose failure
        // mode is a live contract whose dispute path can never run.
        //
        // Post-deploy, through the timelock — see README, "Bringing a deployment up":
        //   1. schedule `registerCurator(curatorN, weight)` for each panel member
        //   2. once the delay has elapsed, each curator calls `fundCuratorBond()`. The panel is
        //      unbonded until they do, and an unbonded curator's ballot does not carry weight.
        //   3. schedule `registerAttester(...)` for the committee, who then `fundAttesterBond()`
        //
        // `Verify` below checks all of that rather than trusting the deploy to have done it.
    }
}

/// @dev Read-only post-deploy assertions, so a deployment is checked against what it actually is
/// rather than against what the deploy script intended. Kept out of `Deploy` because a
/// verification that *can* broadcast is a verification someone will eventually broadcast by
/// accident, and its failure mode is a stray governance call.
///
///   forge script script/Deploy.s.sol:Verify --rpc-url <url> GLT=<addr> TIMELOCK=<addr>
///
/// Every check is one the constructor cannot enforce, because each depends on the timelock's
/// post-construction state rather than on arguments.
contract Verify is Script {
    /// @dev Named `run` so `forge script ...:Verify` works. A `verify()` entry point is
    /// unreachable from the CLI: the script runner looks for `run` and errors with
    /// "Function `run` not found in the ABI" rather than trying anything else.
    function run() external view {
        GalacticTrust glt = GalacticTrust(vm.envAddress("GLT"));
        TimelockController tl = TimelockController(payable(vm.envAddress("TIMELOCK")));

        // The single most important check in the file. If GLT's owner is not the timelock,
        // every governance guarantee in the README is decorative.
        require(glt.owner() == address(tl), "owner is not the timelock");
        require(tl.getMinDelay() > 0, "timelock has no delay");
        require(!tl.hasRole(tl.PROPOSER_ROLE(), address(0)), "address(0) can propose");
        // `address(0)` holding EXECUTOR_ROLE is the intended open-execution setup, not a fault.

        // A zero bond means free signing and free challenging, which reinstates exactly the
        // griefing vectors the bonds exist to close.
        require(glt.attesterBondAmount() > 0, "attester bond is zero");
        require(glt.challengeBondAmount() > 0, "challenge bond is zero");
        require(glt.curatorBondAmount() > 0, "curator bond is zero");

        // A curator who cannot afford the bond cannot rule. This is the check that actually
        // bites on a fresh deploy: every constructor parameter looks correct and the dispute
        // path is still dead, because the panel has no bonded members.
        require(
            glt.outstandingCuratorBond() >= glt.curatorBondAmount(),
            "no curator is bonded, so the panel cannot rule on anything"
        );
        require(glt.totalCuratorWeight() > 0, "no curator is appointed");

        // Held must cover owed from the first block, before a single attestation exists.
        require(glt.balanceOf(address(glt)) >= glt.totalLiabilities(), "contract owes more than it holds at deploy");

        console.log("GLT                  ", address(glt));
        console.log("owner                ", glt.owner());
        console.log("timelock delay       ", tl.getMinDelay());
        console.log("minStake             ", glt.minStake());
        console.log("reward               ", glt.rewardAmount());
        console.log("attester weight      ", glt.totalAttesterWeight());
        console.log("curator weight       ", glt.totalCuratorWeight());
        console.log("attester bond amount ", glt.attesterBondAmount());
        console.log("challenge bond amount", glt.challengeBondAmount());
        console.log("curator bond amount  ", glt.curatorBondAmount());
        console.log("curator bond funded  ", glt.outstandingCuratorBond());
        console.log("verifier             ", address(glt.verifier()));
        console.log("held                 ", glt.balanceOf(address(glt)));
        console.log("owed                 ", glt.totalLiabilities());
        console.log("");
        console.log("all post-deploy checks passed");
    }
}
