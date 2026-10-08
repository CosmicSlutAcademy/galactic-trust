// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {GalacticTrust} from "../src/GalacticTrust.sol";
import {IVerifier, EvidenceVerdict} from "../src/IVerifier.sol";

/// @dev The fixture's evidence gate. The invariant fixture used to deploy with `address(0)`,
/// which makes every verdict CONFIRMED and leaves the whole referral half of the contract
/// unreachable — REFUTED and UNRESOLVED attestations are routed to a curator panel with *no*
/// challenger present, and neither that path nor `panelOverride` was ever exercised by the
/// stateful suite. Both routes are only reachable through a non-CONFIRMED verdict, so the
/// fixture has to be able to produce one.
///
/// `perHash` derives the verdict from the evidence hash rather than from mutable state. A single
/// global verdict would mean every attestation in a run shares one fate, and a run would only
/// ever exercise one branch. Hashing means a run naturally sees a mix of all three, plus a
/// reverting verifier (`k == 0`), which is the outage case `_verdict` is supposed to absorb.
contract MockGate is IVerifier {
    EvidenceVerdict public globalVerdict;
    bool public shouldRevert;
    bool public perHash;

    constructor(EvidenceVerdict _globalVerdict) {
        globalVerdict = _globalVerdict;
    }

    function setGlobalVerdict(EvidenceVerdict v) external {
        globalVerdict = v;
    }

    function setShouldRevert(bool r) external {
        shouldRevert = r;
    }

    function setPerHash(bool p) external {
        perHash = p;
    }

    function verifyEvidence(bytes32 evidenceHash, uint8) external view returns (EvidenceVerdict) {
        if (perHash) {
            uint8 k = uint8(uint256(evidenceHash) % 16);
            // A broken proof system, one hash in sixteen. `_verdict` try/catches this into
            // UNRESOLVED, so the run continues instead of halting on every attestation.
            if (k == 0) revert("proof system down");
            if (k < 6) return EvidenceVerdict.UNRESOLVED;
            if (k < 10) return EvidenceVerdict.REFUTED;
            return EvidenceVerdict.CONFIRMED;
        }
        require(!shouldRevert, "proof system down");
        return globalVerdict;
    }
}

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
    MockGate internal immutable gate;

    address[] internal actors;
    bytes32[] internal ids;
    uint256 internal nonce;

    /// @dev Id of a live attestation whose `contentHash` is all zeroes, used by the outage
    /// invariant below. Zero bytes 32 is: (a) a hash the `perHash` gate reverts on by
    /// construction, and (b) not something a normal `submit` can produce, because the handler
    /// derives its content hash from a nonce. Submitted once and kept for the run's duration.
    bytes32 internal zeroHashId;
    bool internal zeroHashSubmitted;

    constructor(GalacticTrust _glt, MockGate _gate, address _funder, address[] memory _actors) {
        GLT = _glt;
        gate = _gate;
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

    function probeId() external view returns (bytes32) {
        return zeroHashId;
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

    /// @dev The owner swapping the evidence gate mid-run. Two things get exercised that nothing
    /// else reaches: a verdict that *changes* while attestations are in flight, and removing the
    /// gate entirely (`address(0)` → every verdict CONFIRMED). The second is why the handler
    /// never asserts the gate is present.
    function configureVerifier(uint256 seed) external {
        uint256 mode = bound(seed, 0, 4);
        // The gate is unauthenticated, so it is configured directly. `vm.prank` is armed
        // immediately before `setVerifier` rather than at the top: a single `prank` applies to
        // the *next* call only, and putting it first meant it was consumed by `setPerHash`,
        // leaving `setVerifier` to revert `Ownable` on every single call. The handler still
        // reported green because the call sat inside the fuzzer's call accounting, not a
        // try/catch — 440 calls, 440 reverts, and the fixture's verifier never changed.
        // **Check the handler's revert column; a high ratio means the operation is not running.**
        address next = mode == 4 ? address(0) : address(gate);
        if (mode == 0) {
            // Per-hash: a mix of CONFIRMED / REFUTED / UNRESOLVED / reverting in one run.
            gate.setPerHash(true);
        } else if (mode == 1) {
            gate.setPerHash(false);
            gate.setShouldRevert(false);
            gate.setGlobalVerdict(EvidenceVerdict.REFUTED);
        } else if (mode == 2) {
            gate.setPerHash(false);
            gate.setShouldRevert(false);
            gate.setGlobalVerdict(EvidenceVerdict.UNRESOLVED);
        } else if (mode == 3) {
            // A globally broken proof system. Every attestation becomes UNRESOLVED, so all of
            // them route to the panel. This is the outage case at full blast.
            gate.setPerHash(false);
            gate.setShouldRevert(true);
        } else {
            // The gate is removed entirely: absence of an opinion is not an objection.
            gate.setShouldRevert(false);
        }
        vm.prank(GLT.owner());
        GLT.setVerifier(next);
    }

    function claim(uint256 actorSeed, uint256 idSeed) external {
        if (ids.length == 0) return;
        address a = _actor(actorSeed);
        bytes32 id = _id(idSeed);
        vm.prank(a);
        try GLT.claimChallengeReward(id) {} catch {}
    }

    /// @dev Submits one attestation with an all-zero content hash so the outage invariant has a
    /// live record whose gate lookup is guaranteed to revert. Done at most once per run: the id
    /// is derived from the submitter, content hash, timestamp and secret, and a repeat inside the
    /// same block would silently collide and overwrite the first.
    function submitZeroHash() external {
        if (zeroHashSubmitted) return;
        zeroHashSubmitted = true;
        address a = _actor(0);
        vm.prank(a);
        try GLT.submitAttestation(bytes32(0), keccak256("zero-hash-probe"), GalacticTrust.EvidenceTier.R3) returns (
            bytes32 id
        ) {
            zeroHashId = id;
        } catch {
            zeroHashSubmitted = false;
        }
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
    MockGate internal gate;
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

        // A real gate, so REFUTED and UNRESOLVED verdicts occur and the referral routes — a
        // curator panel ruling on an *unchallenged* attestation, and the `panelOverride` that
        // rejection sets — are exercised. With `address(0)` every verdict was CONFIRMED and the
        // whole non-CONFIRMED half of the contract was unreachable from this suite.
        gate = new MockGate(EvidenceVerdict.CONFIRMED);
        glt = new GalacticTrust(address(this), MIN_STAKE, address(gate), TREASURY, funder);

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

        handler = new Handler(glt, gate, funder, actors);
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
                    || a.status == GalacticTrust.AttestationStatus.EXPIRED
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

    /// @dev An override is a *record that the humans overruled the machine*, so it may only exist
    /// when a panel actually rejected by a strict majority. This is the falsifiable form of that
    /// claim: an earlier version asserted "finalized against a non-CONFIRMED verdict implies an
    /// override", which was **vacuous** — `finalizeAttestation` enforces exactly that condition
    /// itself, so no such finalization can ever be recorded and the assertion could not fail.
    /// Deleting the `panelOverride = true` line in `_resolve` left it green.
    ///
    /// This caught two real bugs. `expireReview` defaults a stalled panel to *reject*, so an
    /// unattended expiry — and a panel deadlocked into an exact tie — both set the override
    /// without any overruling having happened.
    function invariant_OverrideOnlyEverComesFromARejectingPanel() public view {
        uint256 tracked = handler.trackedCount();
        for (uint256 i = 0; i < tracked; i++) {
            bytes32 id = handler.trackedAt(i);
            if (!glt.getAttestation(id).panelOverride) continue;
            assertGt(
                glt.rejectWeight(id), glt.upholdWeight(id), "an override was recorded on a ruling that did not reject"
            );
        }
    }

    /// @dev An override marks the attestation as human-approved, so a *slashed* one must never carry
    /// it: an integrator reading `panelOverride` would treat a punished submission as approved.
    /// FINALIZED is deliberately allowed, because finalizing is the whole point of the flag.
    ///
    /// The first version of this asserted the attestation could never be terminal at all, which
    /// was simply wrong — it failed on the override's intended use. A property that forbids the
    /// feature it is meant to describe is a property that gets "fixed" by deleting the feature.
    function invariant_SlashedAttestationsNeverAdvertiseAnOverride() public view {
        uint256 tracked = handler.trackedCount();
        for (uint256 i = 0; i < tracked; i++) {
            GalacticTrust.Attestation memory a = glt.getAttestation(handler.trackedAt(i));
            if (a.status != GalacticTrust.AttestationStatus.SLASHED) continue;
            assertFalse(a.panelOverride, "a slashed attestation still advertises a human override");
        }
    }

    /// @dev The failsafe, as a property rather than a comment. `_verdict` try/catches a reverting
    /// verifier into UNRESOLVED, so a broken proof system must never halt the contract or read
    /// as CONFIRMED — the latter is the silent-mint failure the whole tri-state design exists to
    /// prevent.
    ///
    /// Read by asking the gate directly rather than reading `gate.shouldRevert()`, which was the
    /// first version's mistake: `configureVerifier` can be in `perHash` mode simultaneously,
    /// where the flag is ignored and the revert comes from the evidence hash instead. **A
    /// precondition that reads a different source of truth than the code under test is a
    /// precondition that is silently false.** A low-level staticcall is the only way to observe
    /// "the verifier reverts" from outside.
    ///
    /// The probe uses an all-zero evidence hash rather than a tracked attestation's, for the same
    /// reason. `trackedAt(0)` reverts only when its own hash lands in the 1-in-16 bucket, so the
    /// assertion was silent on ~15 of every 16 runs — vacuous in practice despite being
    /// non-vacuous in principle. Hash zero is in the bucket by construction, so the probe fires
    /// whenever the fixture is actually in an outage configuration and stays quiet otherwise.
    function invariant_VerifierOutageDegradesRatherThanHalting() public view {
        bytes32 id = handler.probeId();
        if (id == bytes32(0)) return; // `submitZeroHash` has not run, or failed to submit
        // Ask the *configured* verifier, and only when one is configured. `configureVerifier`
        // can set `address(0)`, where GLT short-circuits to CONFIRMED without calling anything
        // — probing the mock in that state asserts a degradation that is not supposed to
        // happen, which is the same "wrong source of truth" mistake one layer up.
        address configured = address(glt.verifier());
        if (configured == address(0)) return;
        (bool ok, bytes memory ret) = configured.staticcall(abi.encodeCall(IVerifier.verifyEvidence, (bytes32(0), 0)));
        if (ok && ret.length == 32) return; // the gate has an opinion; nothing to degrade
        assertEq(
            uint8(glt.evidenceVerdict(id)),
            uint8(EvidenceVerdict.UNRESOLVED),
            "a reverting verifier must degrade to UNRESOLVED, never CONFIRMED"
        );
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
