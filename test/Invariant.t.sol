// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {GalacticTrust} from "../src/GalacticTrust.sol";

/// @dev Stateful fuzzer for the settlement layer. Fuzz.t.sol samples parameters on a single
/// scripted lifecycle; this drives long arbitrary sequences of calls against live state, which
/// is the only way to reach orderings nobody thought to write down — two disputes settling out
/// of order, a withdrawal racing a vote, an owner burning mid-flight.
///
/// Two rules keep it usable:
///   1. **No handler call may revert.** Every external call into GLT is wrapped in try/catch. A
///      reverting handler aborts the whole invariant run, so a precondition miss has to be a
///      no-op rather than a failure.
///   2. **All state is `internal`.** Public state variables generate getters, and the fuzzer
///      would happily call them alongside the real operations. Only the intended operations and
///      a few read accessors should be reachable.
contract Handler is Test {
    /// @dev Bounded so the `invariant_*` checks that iterate tracked attestations stay cheap.
    /// Without a cap, id growth x run depth makes every check quadratic in sequence length.
    uint256 internal constant MAX_TRACKED = 48;

    GalacticTrust internal immutable GLT;
    address internal immutable funder;

    address[] internal actors;
    bytes32[] internal ids;
    uint256 internal nonce;

    constructor(GalacticTrust _glt, address _funder, address[] memory _actors) {
        GLT = _glt;
        funder = _funder;
        actors = _actors;
    }

    // ---------- accessors for the invariant checks ----------

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    function trackedCount() external view returns (uint256) {
        return ids.length;
    }

    function trackedAt(uint256 i) external view returns (bytes32) {
        return ids[i];
    }

    // ---------- operations ----------

    /// @dev Distinct secret per call via a monotonic nonce. The id is derived from the submitter,
    /// content hash, timestamp and secret, and invariant runs only move the clock when `warp`
    /// fires — so two submissions in the same block with the same secret would collide and
    /// silently overwrite each other.
    function submit(uint256 seed) external {
        address a = _actor(seed);
        nonce++;
        bytes32 secret = keccak256(abi.encode("invariant", nonce));
        GalacticTrust.EvidenceTier tier = GalacticTrust.EvidenceTier(uint8(bound(seed, 1, 6)));
        vm.prank(a);
        try GLT.submitAttestation(keccak256(abi.encode(secret, a)), secret, tier) returns (bytes32 id) {
            if (ids.length < MAX_TRACKED) ids.push(id);
        } catch {}
    }

    function sign(uint256 actorSeed, uint256 idSeed) external {
        if (ids.length == 0) return;
        address a = _actor(actorSeed);
        bytes32 id = _id(idSeed);
        vm.prank(a);
        try GLT.signAttestation(id) {} catch {}
    }

    function challenge(uint256 actorSeed, uint256 idSeed) external {
        if (ids.length == 0) return;
        address a = _actor(actorSeed);
        bytes32 id = _id(idSeed);
        vm.prank(a);
        try GLT.challengeAttestation(id, "invariant") {} catch {}
    }

    function vote(uint256 actorSeed, uint256 idSeed, bool uphold) external {
        if (ids.length == 0) return;
        address a = _actor(actorSeed);
        bytes32 id = _id(idSeed);
        vm.prank(a);
        try GLT.castCuratorVote(id, uphold) {} catch {}
    }

    function tally(uint256 idSeed) external {
        if (ids.length == 0) return;
        bytes32 id = _id(idSeed);
        try GLT.tallyDispute(id) {} catch {}
    }

    function expire(uint256 idSeed) external {
        if (ids.length == 0) return;
        bytes32 id = _id(idSeed);
        try GLT.expireReview(id) {} catch {}
    }

    function finalize(uint256 idSeed) external {
        if (ids.length == 0) return;
        bytes32 id = _id(idSeed);
        try GLT.finalizeAttestation(id) {} catch {}
    }

    function claim(uint256 actorSeed, uint256 idSeed) external {
        if (ids.length == 0) return;
        address a = _actor(actorSeed);
        bytes32 id = _id(idSeed);
        vm.prank(a);
        try GLT.claimChallengeReward(id) {} catch {}
    }

    function reveal(uint256 actorSeed, uint256 idSeed, uint256 guessSeed) external {
        if (ids.length == 0) return;
        address a = _actor(actorSeed);
        bytes32 id = _id(idSeed);
        bytes32 guess = keccak256(abi.encode("guess", guessSeed));
        vm.prank(a);
        try GLT.revealSecret(id, guess) {} catch {}
    }

    /// @dev Forward only. `vm.warp` will not accept a negative delta, and letting the fuzzer pick
    /// one would make the chain time non-monotonic.
    function warp(uint256 seed) external {
        vm.warp(block.timestamp + bound(seed, 1 hours, 10 days));
    }

    /// @dev Deactivating zeroes weight, which changes the *live* quorum bar. In-flight
    /// attestations snapshotted theirs, so this is the cheapest way to exercise that the
    /// snapshot actually holds under churn.
    function toggleAttester(uint256 actorSeed, bool on) external {
        address a = _actor(actorSeed);
        vm.prank(GLT.owner());
        if (on) {
            try GLT.registerAttester(a, 100) {} catch {}
        } else {
            try GLT.deactivateAttester(a) {} catch {}
        }
    }

    function toggleCurator(uint256 actorSeed, bool on) external {
        address a = _actor(actorSeed);
        vm.prank(GLT.owner());
        if (on) {
            try GLT.registerCurator(a, 100) {} catch {}
        } else {
            try GLT.deactivateCurator(a) {} catch {}
        }
    }

    function topUp(uint256 seed) external {
        address a = _actor(seed);
        vm.prank(funder);
        try GLT.transfer(a, bound(seed, 1e18, 500e18)) {} catch {}
    }

    function fundBonds(uint256 actorSeed) external {
        address a = _actor(actorSeed);
        vm.prank(a);
        try GLT.fundAttesterBond(GLT.attesterBondAmount()) {} catch {}
        vm.prank(a);
        try GLT.fundChallengeBond(GLT.challengeBondAmount()) {} catch {}
        vm.prank(a);
        try GLT.fundCuratorBond(GLT.curatorBondAmount()) {} catch {}
    }

    function withdrawBonds(uint256 actorSeed) external {
        address a = _actor(actorSeed);
        vm.startPrank(a);
        try GLT.withdrawAttesterBond() {} catch {}
        try GLT.withdrawChallengeBond() {} catch {}
        try GLT.withdrawCuratorBond() {} catch {}
        vm.stopPrank();
    }

    /// @dev The owner's burn path, bounded by the current excess so it can only ever touch
    /// unbacked balance. If solvency is violated by a settlement bug, this is the call most
    /// likely to notice it by pushing the contract to the edge.
    function recoverExcess(uint256 seed) external {
        vm.prank(GLT.owner());
        try GLT.recoverExcessStake(bound(seed, 0, GLT.excessBalance())) {} catch {}
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    function _id(uint256 seed) internal view returns (bytes32) {
        return ids[bound(seed, 0, ids.length - 1)];
    }
}

/// @dev Long arbitrary call sequences against live settlement state. The fuzz suite proves
/// conservation along one scripted lifecycle per run; this proves it along sequences nobody
/// chose, which is where the ordering bugs live.
///
/// The properties are deliberately about the *book*, not just the balance. SESSION.md records a
/// bug where `balanceOf(address(this))` was exactly right and only `totalStaked` was wrong, and
/// another where settlement was correct but the panel had already moved on. `held >= owed` alone
/// walks straight past both.
contract InvariantTest is StdInvariant, Test {
    GalacticTrust internal glt;
    Handler internal handler;

    uint256 internal constant MIN_STAKE = 100e18;
    uint256 internal constant ATTESTER_BOND = 100e18;
    uint256 internal constant CHALLENGE_BOND = 50e18;
    uint256 internal constant CURATOR_BOND = 200e18;
    uint256 internal constant REWARD = 10e18;
    uint256 internal constant TREASURY = 20_000_000e18;
    uint256 internal constant ACTOR_FUNDING = 20_000e18;
    uint256 internal constant N_ACTORS = 5;

    function setUp() public {
        address funder = makeAddr("funder");

        // No verifier, so every verdict is CONFIRMED and the panel is reached through challenges
        // rather than referrals. That keeps curator quorum reachable and the sequence generator
        // busy instead of stalling on a gate nothing in this fixture can satisfy.
        glt = new GalacticTrust(address(this), MIN_STAKE, address(0), TREASURY, funder);

        address[] memory actors = new address[](N_ACTORS);
        for (uint256 i = 0; i < N_ACTORS; i++) {
            actors[i] = makeAddr(string.concat("actor", vm.toString(i)));
            glt.registerAttester(actors[i], 100);
            glt.registerCurator(actors[i], 100);
            vm.prank(funder);
            glt.transfer(actors[i], ACTOR_FUNDING);
        }

        glt.setRewardAmount(REWARD);
        glt.setAttesterBondAmount(ATTESTER_BOND);
        glt.setChallengeBondAmount(CHALLENGE_BOND);
        glt.setCuratorBondAmount(CURATOR_BOND);

        // Bonds are funded after the amounts are set, so every actor starts above every bar.
        for (uint256 i = 0; i < N_ACTORS; i++) {
            vm.prank(actors[i]);
            glt.fundAttesterBond(ATTESTER_BOND);
            vm.prank(actors[i]);
            glt.fundChallengeBond(CHALLENGE_BOND);
            vm.prank(actors[i]);
            glt.fundCuratorBond(CURATOR_BOND);
        }

        handler = new Handler(glt, funder, actors);
        targetContract(address(handler));
    }

    /// @dev The one that matters most, and the one SESSION.md §6 asks for by name.
    function invariant_HeldCoversOwed() public view {
        assertGe(glt.balanceOf(address(glt)), glt.totalLiabilities(), "contract owes more than it holds");
    }

    /// @dev Every bond total must equal the sum of the per-account balances behind it. A burn
    /// that updates the account but not the total leaves the contract reporting liabilities it
    /// has already paid out, which reads as insolvent long after it stopped being so.
    function invariant_AttesterBondBookMatchesAccounts() public view {
        assertEq(
            glt.outstandingAttesterBond(),
            _sumAttesterBond(),
            "outstandingAttesterBond drifted from the per-account balances"
        );
    }

    function invariant_ChallengeBondBookMatchesAccounts() public view {
        assertEq(
            glt.outstandingChallengeBond(),
            _sumChallengeBond(),
            "outstandingChallengeBond drifted from the per-account balances"
        );
    }

    function invariant_CuratorBondBookMatchesAccounts() public view {
        assertEq(
            glt.outstandingCuratorBond(),
            _sumCuratorBond(),
            "outstandingCuratorBond drifted from the per-account balances"
        );
    }

    /// @dev `totalStaked` may only ever be backed by stake that is still PENDING. Subtracting
    /// only the burned leg of a slash double-counts the remainder as both stake and challenge
    /// escrow at once, which is the bug the fuzz suite caught once already.
    function invariant_TerminalAttestationsRetainNoStake() public view {
        uint256 tracked = handler.trackedCount();
        for (uint256 i = 0; i < tracked; i++) {
            GalacticTrust.Attestation memory a = glt.getAttestation(handler.trackedAt(i));
            if (
                a.status == GalacticTrust.AttestationStatus.FINALIZED
                    || a.status == GalacticTrust.AttestationStatus.SLASHED
            ) {
                assertEq(a.stake, 0, "a terminal attestation still counts stake");
            }
        }
    }

    /// @dev Tracked attestations' live stake can never exceed the book. `assertLe` rather than
    /// equality because the handler caps how many ids it remembers, so the book legitimately
    /// covers attestations this run never observed.
    function invariant_LiveStakeNeverExceedsTotalStaked() public view {
        uint256 live;
        uint256 tracked = handler.trackedCount();
        for (uint256 i = 0; i < tracked; i++) {
            GalacticTrust.Attestation memory a = glt.getAttestation(handler.trackedAt(i));
            if (a.status == GalacticTrust.AttestationStatus.PENDING) live += a.stake;
        }
        assertLe(live, glt.totalStaked(), "tracked live stake exceeds totalStaked");
    }

    /// @dev Unclaimed challenge entitlements can never exceed the escrow booked for them. This
    /// is the multi-challenger payout bug: the pool figure was right while the per-challenger
    /// shares were not, so the first claimant drained it and the rest found nothing waiting.
    function invariant_UnclaimedSharesNeverExceedPayoutEscrow() public view {
        uint256 unclaimed;
        uint256 tracked = handler.trackedCount();
        uint256 actors = handler.actorCount();
        for (uint256 i = 0; i < tracked; i++) {
            bytes32 id = handler.trackedAt(i);
            for (uint256 j = 0; j < actors; j++) {
                unclaimed += glt.payoutShare(id, handler.actorAt(j));
            }
        }
        assertLe(unclaimed, glt.totalPayoutEscrow(), "unclaimed shares exceed payout escrow");
    }

    function _sumAttesterBond() internal view returns (uint256 sum) {
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            sum += glt.attesterBond(handler.actorAt(i));
        }
    }

    function _sumChallengeBond() internal view returns (uint256 sum) {
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            sum += glt.challengeBond(handler.actorAt(i));
        }
    }

    function _sumCuratorBond() internal view returns (uint256 sum) {
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            sum += glt.curatorBond(handler.actorAt(i));
        }
    }
}
