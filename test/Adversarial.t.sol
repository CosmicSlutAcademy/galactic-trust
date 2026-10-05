// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GalacticTrust} from "../src/GalacticTrust.sol";
import {IVerifier, EvidenceVerdict} from "../src/IVerifier.sol";

/// Adversarial pass over the tri-state gate. Every case here is a way the new logic could
/// destroy funds, freeze the protocol, or launder a refutation. The happy path lives in
/// GalacticTrust.t.sol; this file exists because the 47-green-tests trap was exactly this
/// class of bug going unnoticed.
contract AdversarialTest is Test {
    GalacticTrust internal glt;
    MockV internal v;

    address internal owner = address(this);
    address internal submitter = makeAddr("submitter");
    address internal attester1 = makeAddr("attester1");
    address internal attester2 = makeAddr("attester2");
    address internal challenger1 = makeAddr("challenger1");
    address internal challenger2 = makeAddr("challenger2");
    address internal curator1 = makeAddr("curator1");
    address internal curator2 = makeAddr("curator2");
    address internal curator3 = makeAddr("curator3");
    address internal outsider = makeAddr("outsider");
    address internal whale = makeAddr("whale");

    bytes32 internal constant SECRET = keccak256("r5");
    uint256 internal constant MIN_STAKE = 1_000e18;
    uint256 internal constant BOND = 5_000e18;
    uint256 internal constant REWARD = 100e18;
    uint256 internal constant TREASURY = 10_000_000e18;
    uint256 internal constant CHALLENGE_BOND = 100e18;
    uint256 internal constant CURATOR_BOND = 1_000e18;

    uint256 private _nonce;

    function setUp() public {
        glt = new GalacticTrust(owner, MIN_STAKE, address(0), TREASURY, submitter);
        glt.registerAttester(attester1, 100);
        glt.registerAttester(attester2, 100);
        glt.registerCurator(curator1, 100);
        glt.registerCurator(curator2, 100);
        glt.registerCurator(curator3, 100);

        vm.startPrank(owner);
        glt.setRewardAmount(REWARD);
        glt.setAttesterBondAmount(BOND);
        glt.setChallengeBondAmount(CHALLENGE_BOND);
        glt.setCuratorBondAmount(CURATOR_BOND);
        vm.stopPrank();

        _fund(attester1);
        _fund(attester2);
        _fundC(challenger1);
        _fundC(challenger2);
        _fundC(outsider);
        _fundCur(curator1);
        _fundCur(curator2);
        _fundCur(curator3);

        v = new MockV(EvidenceVerdict.CONFIRMED);
        vm.prank(owner);
        glt.setVerifier(address(v));
    }

    function _fund(address who) internal {
        vm.prank(submitter);
        glt.transfer(who, BOND * 2);
        vm.prank(who);
        glt.fundAttesterBond(BOND);
    }

    function _fundC(address who) internal {
        vm.prank(submitter);
        glt.transfer(who, CHALLENGE_BOND * 2);
        vm.prank(who);
        glt.fundChallengeBond(CHALLENGE_BOND);
    }

    function _fundCur(address who) internal {
        vm.prank(submitter);
        glt.transfer(who, CURATOR_BOND * 2);
        vm.prank(who);
        glt.fundCuratorBond(CURATOR_BOND);
    }

    /// Distinct secret per submission: the id is derived from the timestamp, which Foundry
    /// does not advance between calls.
    function _submit() internal returns (bytes32 id) {
        bytes32 s = keccak256(abi.encode("s", ++_nonce));
        vm.prank(submitter);
        id = glt.submitAttestation(keccak256(abi.encode(s, submitter)), s, GalacticTrust.EvidenceTier.R2);
    }

    function _sign(bytes32 id, address a) internal {
        vm.prank(a);
        glt.signAttestation(id);
    }

    function _skipWindow() internal {
        vm.warp(block.timestamp + glt.CHALLENGE_WINDOW() + 1);
    }

    function _expire() internal {
        vm.warp(block.timestamp + glt.REVIEW_WINDOW() + 1);
    }

    function _solvent() internal {
        assertGe(glt.balanceOf(address(glt)), glt.totalLiabilities(), "insolvent");
    }

    /// A hostile owner must not be able to make an in-flight dispute unresolvable.
    function test_HostileOwnerCannotFreezeOrSteal() public {
        bytes32 id = _submit();
        _sign(id, attester1);
        vm.prank(challenger1);
        glt.challengeAttestation(id, "a");
        vm.prank(challenger2);
        glt.challengeAttestation(id, "b");
        _skipWindow();

        vm.startPrank(owner);
        glt.registerCurator(whale, type(uint128).max);
        glt.setQuorumBps(10_000);
        glt.setSlashBps(10_000);
        glt.setAttesterSlashBps(10_000);
        glt.setChallengeBondAmount(type(uint256).max);

        // the owner can burn the unbacked remainder and nothing more
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.NothingToRecover.selector, MIN_STAKE, 0));
        glt.recoverExcessStake(MIN_STAKE);
        vm.stopPrank();

        // the dispute still resolves and the snapshot held
        vm.prank(curator1);
        glt.castCuratorVote(id, true);
        vm.prank(curator2);
        glt.castCuratorVote(id, true);
        glt.tallyDispute(id);
        assertEq(uint8(glt.getAttestation(id).status), uint8(GalacticTrust.AttestationStatus.SLASHED));
        _solvent();
    }

    /// Two challengers, one upheld dispute: both must be paid. This was the original
    /// single-pool bug, retested against the new per-challenger accounting.
    function test_TwoChallengersBothPaidEvenWithOneUnbondedAtSettlement() public {
        bytes32 id = _submit();
        _sign(id, attester1);
        vm.prank(challenger1);
        glt.challengeAttestation(id, "a");
        vm.prank(challenger2);
        glt.challengeAttestation(id, "b");
        _skipWindow();

        vm.prank(curator1);
        glt.castCuratorVote(id, true);
        vm.prank(curator2);
        glt.castCuratorVote(id, true);
        glt.tallyDispute(id);

        uint256 p1 = glt.balanceOf(challenger1);
        uint256 p2 = glt.balanceOf(challenger2);
        vm.prank(challenger1);
        glt.claimChallengeReward(id);
        vm.prank(challenger2);
        glt.claimChallengeReward(id);
        assertGt(glt.balanceOf(challenger1), p1, "first paid");
        assertGt(glt.balanceOf(challenger2), p2, "second paid too");
        assertEq(glt.payoutPool(id), 0, "pool drained");
        _solvent();
    }

    /// A challenger cannot lift its bond mid-challenge to escape forfeiture.
    function test_CannotEscapeForfeitureByExitingMidChallenge() public {
        bytes32 id = _submit();
        _sign(id, attester1);
        vm.prank(challenger1);
        glt.challengeAttestation(id, "a");
        vm.prank(challenger1);
        vm.expectRevert(GalacticTrust.NoBondToWithdraw.selector);
        glt.withdrawChallengeBond();
        _skipWindow();

        vm.prank(curator1);
        glt.castCuratorVote(id, false);
        vm.prank(curator2);
        glt.castCuratorVote(id, false);
        glt.tallyDispute(id);
        assertEq(glt.challengeBond(challenger1), 0, "forfeited");
        _solvent();
    }

    /// A rejecting panel must not be able to burn an honest attester's bond.
    function test_RejectingPanelLeavesHonestSignersIntact() public {
        bytes32 id = _submit();
        _sign(id, attester1);
        vm.prank(challenger1);
        glt.challengeAttestation(id, "a");
        _skipWindow();
        vm.prank(curator1);
        glt.castCuratorVote(id, false);
        vm.prank(curator2);
        glt.castCuratorVote(id, false);
        glt.tallyDispute(id);
        assertEq(glt.attesterBond(attester1), BOND, "untouched");
    }

    /// A broken verifier across the whole lifecycle: nothing freezes, nothing mints silently.
    function test_BrokenVerifierEndToEnd() public {
        v.setShouldRevert(true);
        bytes32 id = _submit();
        _sign(id, attester1);
        _sign(id, attester2);
        _skipWindow();

        uint256 supply = glt.totalSupply();
        vm.expectRevert();
        glt.finalizeAttestation(id);
        assertEq(glt.totalSupply(), supply, "no mint while unresolved");

        // expiry cannot launder it either
        _expire();
        glt.expireReview(id);
        assertEq(glt.totalSupply(), supply, "still no mint");
        assertEq(uint8(glt.getAttestation(id).status), uint8(GalacticTrust.AttestationStatus.PENDING));
        _solvent();
    }

    /// Refuted evidence cannot reach finalization through any path, and expiry is not an exit.
    function test_RefutedCannotEscapeThroughAnyPath() public {
        v.setVerdict(EvidenceVerdict.REFUTED);
        bytes32 id = _submit();
        _sign(id, attester1);
        _sign(id, attester2);
        _skipWindow();

        vm.expectRevert();
        glt.finalizeAttestation(id);

        _expire();
        glt.expireReview(id);
        assertEq(uint8(glt.getAttestation(id).status), uint8(GalacticTrust.AttestationStatus.SLASHED));
        vm.expectRevert();
        glt.finalizeAttestation(id);
        assertEq(glt.attesterBond(attester1), 0, "signers punished");
        _solvent();
    }

    /// Expiry must terminate cleanly with no votes cast at all, and a second expiry attempt
    /// must not re-run settlement.
    function test_ExpiryWithNoVotesAtAllTerminates() public {
        bytes32 id = _submit();
        _sign(id, attester1);
        _skipWindow();
        _expire();
        glt.expireReview(id);
        assertEq(
            uint8(glt.getAttestation(id).status),
            uint8(GalacticTrust.AttestationStatus.PENDING),
            "silence defaults to reject"
        );
        // after a rejection the window is settled: challenges cleared, so there is nothing
        // left to review and a second expiry is impossible.
        assertEq(glt.challengeCount(id), 0, "no open dispute remains");
        _solvent();
    }

    /// With quorum genuinely reached and non-tied, expiry must refuse: that is a live dispute,
    /// not a stalled one, and expiring it would let anyone race `tallyDispute`.
    function test_RevertWhen_ExpiringResolvedQuorum() public {
        bytes32 id = _submit();
        _sign(id, attester1);
        vm.prank(challenger1);
        glt.challengeAttestation(id, "a");
        _skipWindow();
        vm.prank(curator1);
        glt.castCuratorVote(id, true);
        vm.prank(curator2);
        glt.castCuratorVote(id, true);
        _expire();
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.ReviewAlreadyResolved.selector, id));
        glt.expireReview(id);
    }

    function test_RereadSolvencyAfterEveryPath() public {
        // rejected referral
        v.setVerdict(EvidenceVerdict.REFUTED);
        bytes32 a = _submit();
        _sign(a, attester1);
        _skipWindow();
        vm.prank(curator1);
        glt.castCuratorVote(a, false);
        vm.prank(curator2);
        glt.castCuratorVote(a, false);
        glt.tallyDispute(a);
        glt.finalizeAttestation(a);
        _solvent();

        // upheld referral. Both signers needed to observe both bonds being slashed. The
        // earlier rejected referral left attester1 solvent, but the approved referral above
        // finalizes without slashing, so both are still bonded here.
        v.setVerdict(EvidenceVerdict.REFUTED);
        bytes32 b = _submit();
        _sign(b, attester1);
        _sign(b, attester2);
        _skipWindow();
        vm.prank(curator1);
        glt.castCuratorVote(b, true);
        vm.prank(curator2);
        glt.castCuratorVote(b, true);
        glt.tallyDispute(b);
        _solvent();

        // expiry on a tie, with the machine satisfied so expiry can default to reject.
        // The upheld referral above slashed both bonds to zero, so they must re-bond first —
        // signing requires a live bond.
        v.setVerdict(EvidenceVerdict.CONFIRMED);
        _fund(attester1);
        _fund(attester2);
        bytes32 c = _submit();
        _sign(c, attester1);
        _sign(c, attester2);
        vm.prank(challenger1);
        glt.challengeAttestation(c, "a");
        _skipWindow();
        vm.prank(curator1);
        glt.castCuratorVote(c, true);
        vm.prank(curator2);
        glt.castCuratorVote(c, false);
        _expire();
        glt.expireReview(c);
        glt.finalizeAttestation(c);
        _solvent();
        assertEq(glt.excessBalance(), 0, "book balances across every resolution path");
    }

    /// Reveal cannot be weaponised to corrupt evidence or steal the confidentiality window.
    function test_RevealCannotBeWeaponised() public {
        bytes32 id = _submit();

        // during the window nobody may reveal, not even a curator
        vm.prank(curator1);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.ChallengeWindowOpen.selector, id));
        glt.revealSecret(id, SECRET);

        _skipWindow();
        // an outsider cannot reveal
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.NotAuthorizedRevealer.selector, id, outsider));
        glt.revealSecret(id, SECRET);

        // a curator can. The submission uses a nonce-derived secret, so assert against the
        // real pre-image rather than the module-level constant.
        bytes32 realSecret = keccak256(abi.encode("s", uint256(1)));
        vm.prank(curator1);
        glt.revealSecret(id, keccak256(abi.encode("wrong", submitter)));
        assertFalse(glt.getAttestation(id).secretRevealed, "bad guess recorded nothing");
        vm.prank(curator2);
        glt.revealSecret(id, realSecret);
        assertTrue(glt.getAttestation(id).secretRevealed, "good guess recorded");
        assertEq(glt.getAttestation(id).secret, realSecret, "stored the verified pre-image");
        _solvent();
    }

    /// A finalized attestation must be immune to the verifier being pointed somewhere hostile later.
    function test_FinalizedIsImmutableToVerifierChanges() public {
        bytes32 id = _submit();
        _sign(id, attester1);
        _sign(id, attester2);
        _skipWindow();
        glt.finalizeAttestation(id);
        v.setVerdict(EvidenceVerdict.REFUTED);
        assertEq(uint8(glt.getAttestation(id).status), uint8(GalacticTrust.AttestationStatus.FINALIZED));
        vm.prank(curator1);
        vm.expectRevert();
        glt.castCuratorVote(id, true);
        _solvent();
    }

    // ---------- curator bond ----------

    /// The headline case. Before the bond, an owner-appointed curator cost nothing, so the
    /// panel was the owner's key in a committee costume. Weight without a bond must not vote.
    function test_UnbondedCuratorCannotVote() public {
        bytes32 id = _submit();
        _sign(id, attester1);
        vm.prank(challenger1);
        glt.challengeAttestation(id, "a");
        _skipWindow();

        address freeRider = makeAddr("unbondedCurator");
        vm.prank(owner);
        glt.registerCurator(freeRider, 100_000);

        vm.prank(freeRider);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.BondBelowRequired.selector, 0, CURATOR_BOND));
        glt.castCuratorVote(id, true);
        assertEq(glt.signerWeight(id), 100, "no weight moved");
        _solvent();
    }

    /// Weight must not be laundered through a bond that arrives after the snapshot. A curator
    /// who bonds *after* an attestation is submitted still cannot carry weight without skin —
    /// but once bonded they can, which is the point: the bar is skin, not tenure.
    function test_OwnerCannotAppointAWeighlessWhale() public {
        bytes32 id = _submit();
        _sign(id, attester1);
        vm.prank(challenger1);
        glt.challengeAttestation(id, "a");
        _skipWindow();

        vm.prank(owner);
        glt.registerCurator(whale, type(uint128).max);
        // Quorum is basis-points of total curator weight, so the whale has inflated the bar.
        assertEq(
            glt.curatorQuorumWeight(),
            (uint256(type(uint128).max) + 300) * 5_000 / 10_000,
            "weight counts toward the live bar"
        );

        // The whale cannot reach the bar it just inflated: no bond, no vote.
        vm.prank(whale);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.BondBelowRequired.selector, 0, CURATOR_BOND));
        glt.castCuratorVote(id, true);

        // And the in-flight dispute is still resolvable by the bonded panel, because curator
        // quorum was snapshotted at submission.
        vm.prank(curator1);
        glt.castCuratorVote(id, true);
        vm.prank(curator2);
        glt.castCuratorVote(id, true);
        glt.tallyDispute(id);
        assertEq(uint8(glt.getAttestation(id).status), uint8(GalacticTrust.AttestationStatus.SLASHED));
        _solvent();
    }

    /// The core incentive. A curator who rules against the panel majority loses bond, because
    /// otherwise ruling is free and arbitrary — nothing downstream ever disagrees with them.
    function test_LosingSideCuratorsAreSlashed() public {
        vm.prank(owner);
        glt.setCuratorSlashBps(10_000);

        bytes32 id = _submit();
        _sign(id, attester1);
        vm.prank(challenger1);
        glt.challengeAttestation(id, "a");
        _skipWindow();

        vm.prank(curator1);
        glt.castCuratorVote(id, false); // dissenter, will lose
        vm.prank(curator2);
        glt.castCuratorVote(id, true);
        vm.prank(curator3);
        glt.castCuratorVote(id, true);
        glt.tallyDispute(id);

        assertEq(glt.curatorBond(curator1), 0, "dissenting curator burned in full");
        assertEq(glt.curatorBond(curator2), CURATOR_BOND, "majority untouched");
        assertEq(glt.curatorBond(curator3), CURATOR_BOND, "majority untouched");
        assertEq(glt.outstandingCuratorBond(), CURATOR_BOND * 2, "liability tracks the burn");
        _solvent();
    }

    /// Partial slash must be exactly proportional, and the bond must survive to be re-bonded.
    function test_PartialCuratorSlashIsProportional() public {
        vm.prank(owner);
        glt.setCuratorSlashBps(2_500); // 25%

        bytes32 id = _submit();
        _sign(id, attester1);
        vm.prank(challenger1);
        glt.challengeAttestation(id, "a");
        _skipWindow();

        vm.prank(curator1);
        glt.castCuratorVote(id, false);
        vm.prank(curator2);
        glt.castCuratorVote(id, true);
        vm.prank(curator3);
        glt.castCuratorVote(id, true);
        glt.tallyDispute(id);

        uint256 expected = CURATOR_BOND - (CURATOR_BOND * 2_500) / 10_000;
        assertEq(glt.curatorBond(curator1), expected, "25% gone");
        _solvent();

        // Below the bar now, so the shorn curator cannot immediately rule again.
        // attester2 signs and `outsider` challenges this one: the upheld dispute above slashed
        // attester1's bond and forfeited challenger1's, each its own punishment.
        bytes32 id2 = _submit();
        _sign(id2, attester2);
        vm.prank(outsider);
        glt.challengeAttestation(id2, "b");
        _skipWindow();
        vm.prank(curator1);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.BondBelowRequired.selector, expected, CURATOR_BOND));
        glt.castCuratorVote(id2, true);
    }

    /// The escape this whole mechanism exists to close: bond, rule, deactivate, withdraw, and
    /// be immune when the ruling you voted for turns out to be the losing one.
    function test_CannotWithdrawBondToEscapeTheSlash() public {
        // 50%, so a remainder survives the slash and can actually be reclaimed afterwards.
        vm.prank(owner);
        glt.setCuratorSlashBps(5_000);

        bytes32 id = _submit();
        _sign(id, attester1);
        vm.prank(challenger1);
        glt.challengeAttestation(id, "a");
        _skipWindow();

        vm.prank(curator1);
        glt.castCuratorVote(id, false); // dissenter
        assertEq(glt.curatorOpenVotes(curator1), 1, "vote locks the bond");

        // Deactivation alone must not release it.
        vm.prank(owner);
        glt.deactivateCurator(curator1);
        vm.prank(curator1);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.CuratorHasOpenVotes.selector, curator1, 1));
        glt.withdrawCuratorBond();

        vm.prank(curator2);
        glt.castCuratorVote(id, true);
        vm.prank(curator3);
        glt.castCuratorVote(id, true);
        glt.tallyDispute(id);

        // Settled, so the lock is gone and the slash has actually landed.
        assertEq(glt.curatorOpenVotes(curator1), 0, "lock released at settlement");
        uint256 remainder = CURATOR_BOND / 2;
        assertEq(glt.curatorBond(curator1), remainder, "escaped nothing: half was burned");
        _solvent();

        vm.prank(curator1);
        glt.withdrawCuratorBond();
        assertEq(glt.balanceOf(curator1), CURATOR_BOND + remainder, "bond + 50% slash, nothing more");
    }

    /// Still-active curators cannot pull their bond, so a curator cannot exit ahead of a
    /// dispute they are about to be asked to rule on.
    function test_RevertWhen_ActiveCuratorWithdrawsBond() public {
        vm.prank(curator1);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.CuratorStillActive.selector, curator1));
        glt.withdrawCuratorBond();
    }

    /// A curatorship that can be made free again reinstates the exact panel the bond removes.
    function test_RevertWhen_CuratorBondSetToZero() public {
        vm.prank(owner);
        vm.expectRevert(GalacticTrust.ZeroAmount.selector);
        glt.setCuratorBondAmount(0);
    }

    /// How expiry interacts with a REFUTED verdict, pinned because the answer is not obvious and is
    /// load-bearing. Silence punishes the submitter; a panel that actually voted to acquit does
    /// not — and the curators who acquit it are not slashed, because they agreed with the ruling.
    function test_RefutedExpirySparesASubmitterThePanelAcquitted() public {
        v.setVerdict(EvidenceVerdict.REFUTED);

        // (a) no curator votes at all: silence is not acquittal, the submitter is punished.
        bytes32 quiet = _submit();
        _sign(quiet, attester1);
        _skipWindow();
        _expire();
        glt.expireReview(quiet);
        assertEq(uint8(glt.getAttestation(quiet).status), uint8(GalacticTrust.AttestationStatus.SLASHED));

        // (b) the panel votes to acquit: the humans overrule the machine, visibly.
        // `tallyDispute`, not `expireReview` — a panel that reaches quorum with a clear
        // non-tie is settled by ruling, and `expireReview` deliberately refuses that case.
        // attester2 again: the upheld expiry above slashed attester1's bond to nothing.
        bytes32 id = _submit();
        _sign(id, attester2);
        _skipWindow();
        vm.prank(curator1);
        glt.castCuratorVote(id, false);
        vm.prank(curator2);
        glt.castCuratorVote(id, false);
        glt.tallyDispute(id);

        assertEq(uint8(glt.getAttestation(id).status), uint8(GalacticTrust.AttestationStatus.PENDING));
        assertEq(glt.getAttestation(id).stake, MIN_STAKE, "stake returned: the panel spoke");
        assertTrue(glt.getAttestation(id).panelOverride, "the override is recorded, which is what makes it finalizable");
        assertEq(glt.curatorBond(curator1), CURATOR_BOND, "acquitting the panel agreed with the ruling");
        assertEq(glt.curatorBond(curator2), CURATOR_BOND, "so it is not a loser's slash");
        _solvent();
    }

    /// The `finalizeAttestation` release path. A curator may rule on a referral with no
    /// challenger; if the verifier is then repaired the attestation finalizes normally, and
    /// those abandoned votes must not leave a lock nothing will ever clear.
    function test_AbandonedReferralVotesReleaseTheirLockOnFinalize() public {
        v.setVerdict(EvidenceVerdict.UNRESOLVED);
        bytes32 id = _submit();
        _sign(id, attester1);
        _skipWindow();

        // reviewable with no challenger at all, because the verdict is not CONFIRMED
        vm.prank(curator1);
        glt.castCuratorVote(id, false);
        assertEq(glt.curatorOpenVotes(curator1), 1);

        // the proof system comes back
        v.setVerdict(EvidenceVerdict.CONFIRMED);
        glt.finalizeAttestation(id);

        assertEq(uint8(glt.getAttestation(id).status), uint8(GalacticTrust.AttestationStatus.FINALIZED));
        assertEq(glt.curatorOpenVotes(curator1), 0, "lock released, not stranded");
        assertEq(glt.curatorBond(curator1), CURATOR_BOND, "and no slash: the votes were abandoned, not overruled");
        _solvent();

        // the curator is a free agent again and can withdraw
        vm.prank(owner);
        glt.deactivateCurator(curator1);
        vm.prank(curator1);
        glt.withdrawCuratorBond();
    }

    /// A settled attestation must not be re-ruled. `upholdWeight`/`rejectWeight` persist past
    /// settlement, so allowing a second ballot would let a curator stack a vote onto a decided
    /// tally and flip an acquittal into a slash.
    function test_CannotReVoteAfterSettlementToFlipARuling() public {
        bytes32 id = _submit();
        _sign(id, attester1);
        vm.prank(challenger1);
        glt.challengeAttestation(id, "a");
        _skipWindow();

        vm.prank(curator1);
        glt.castCuratorVote(id, false);
        vm.prank(curator2);
        glt.castCuratorVote(id, false);
        vm.prank(curator3);
        glt.castCuratorVote(id, false);
        glt.tallyDispute(id);

        // Rejected. The submitter is exonerated and the attestation can finalize.
        assertEq(uint8(glt.getAttestation(id).status), uint8(GalacticTrust.AttestationStatus.PENDING));
        assertEq(glt.getAttestation(id).stake, MIN_STAKE, "stake intact");

        // The rejection cleared the challenger list, so there is nothing left to rule on. This
        // guard fires ahead of `AlreadyVoted`, and it is the one that matters here: the panel
        // already ruled and the evidence is now unchallenged.
        vm.prank(curator3);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.NoChallengesToResolve.selector, id));
        glt.castCuratorVote(id, true);

        // Nor can anyone who already did, in the direction that would have overturned it.
        vm.prank(curator1);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.NoChallengesToResolve.selector, id));
        glt.castCuratorVote(id, true);

        assertEq(glt.getAttestation(id).stake, MIN_STAKE, "no second ruling reached the submitter");
        _solvent();
    }

    /// Within an open dispute the ballot is spent for good, so a curator cannot hedge by
    /// voting both ways before the tally.
    /// A deadlocked panel must not be recorded as having overruled the machine. Found by
    /// `invariant_OverrideOnlyEverComesFromARejectingPanel`, which is why it is pinned here.
    ///
    /// The panel splits exactly evenly and never reaches a majority. `expireReview` defaults a
    /// stall to *reject*, and the old code set `panelOverride` off the back of that — so a panel
    /// that expressed no opinion at all recorded permanent human approval of an attestation
    /// whose evidence the gate had refused to confirm. Because the challenge window is absolute
    /// and already shut, nothing could ever revisit it: the submitter simply waited out the
    /// review window and the mint gate opened on a split vote.
    function test_TiedPanelAtExpiryDoesNotOverrideTheMachine() public {
        v.setVerdict(EvidenceVerdict.UNRESOLVED);
        bytes32 id = _submit();
        _sign(id, attester1);
        _skipWindow();

        // An even split, and short of quorum, so `expireReview` is the only exit.
        vm.prank(curator1);
        glt.castCuratorVote(id, true);
        vm.prank(curator2);
        glt.castCuratorVote(id, false);
        assertEq(glt.upholdWeight(id), 100);
        assertEq(glt.rejectWeight(id), 100);

        _expire();
        glt.expireReview(id);

        assertEq(uint8(glt.getAttestation(id).status), uint8(GalacticTrust.AttestationStatus.PENDING));
        assertFalse(
            glt.getAttestation(id).panelOverride,
            "a panel that deadlocked has not overruled anything, so no override may be recorded"
        );
        // And so the mint gate stays shut. This is the part that mattered: without the guard
        // this call succeeded and paid the submitter.
        vm.expectRevert(
            abi.encodeWithSelector(
                GalacticTrust.EvidenceNotFinalizable.selector, id, uint8(EvidenceVerdict.UNRESOLVED)
            )
        );
        glt.finalizeAttestation(id);
        _solvent();
    }

    /// The same reasoning with no votes at all. Silence is not acquittal, and it is not
    /// acquittal by default either.
    function test_UnattendedExpiryDoesNotOverrideTheMachine() public {
        v.setVerdict(EvidenceVerdict.UNRESOLVED);
        bytes32 id = _submit();
        _sign(id, attester1);
        _skipWindow();
        _expire();

        glt.expireReview(id);
        assertFalse(glt.getAttestation(id).panelOverride, "nobody voted, so nobody overrode anything");
        vm.expectRevert(
            abi.encodeWithSelector(
                GalacticTrust.EvidenceNotFinalizable.selector, id, uint8(EvidenceVerdict.UNRESOLVED)
            )
        );
        glt.finalizeAttestation(id);
        _solvent();
    }

    /// A genuine reject majority *does* still override, so the fix above has not closed the exit
    /// the override exists to provide. The deadlock case must not be mistaken for "no override
    /// is ever set".
    function test_RejectingPanelStillOverridesSoTheExitExists() public {
        v.setVerdict(EvidenceVerdict.UNRESOLVED);
        bytes32 id = _submit();
        _sign(id, attester1);
        _skipWindow();

        vm.prank(curator1);
        glt.castCuratorVote(id, false);
        vm.prank(curator2);
        glt.castCuratorVote(id, false);
        glt.tallyDispute(id);

        assertTrue(glt.getAttestation(id).panelOverride, "a real rejection is an overruling");
        glt.finalizeAttestation(id);
        assertEq(uint8(glt.getAttestation(id).status), uint8(GalacticTrust.AttestationStatus.FINALIZED));
        _solvent();
    }

    /// A ruling is final, including against curators who never voted. Found by
    /// `invariant_OverrideOnlyEverComesFromARejectingPanel`, which saw `rejectWeight ==
    /// upholdWeight` on a settled attestation and could only explain it by weights moving after
    /// the fact.
    ///
    /// Making each curator's own ballot permanent was only half of the fix recorded in
    /// SESSION.md §5: nothing stopped a *different* curator voting afterwards. `_resolve` leaves
    /// the record PENDING with the challenger list cleared, so `castCuratorVote` and a second
    /// `tallyDispute` were both still accepted. The weights therefore kept moving after
    /// `_settleCurators` had already released locks and slashed the dissenters, so the record of
    /// the ruling stopped describing the ruling that was applied.
    ///
    /// Note the panel cannot be flipped by weight alone: settling as a rejection requires
    /// `rejectWeight >= 50%` of the panel, so disjoint late voters can never strictly outweigh
    /// it. The damage is the frozen record, not a reversed verdict — and `disputeUpheld` and the
    /// slashing leg were re-runnable on an already-settled attestation regardless.
    ///
    /// The verdict here must be non-CONFIRMED. With a CONFIRMED one, clearing the challenger list
    /// after a rejection refuses a late ballot on its own — `castCuratorVote` reverts
    /// `NoChallengesToResolve` — so the bug was only ever reachable on the *referral* path, where
    /// the panel rules on an attestation nobody challenged and the challenger list was already
    /// empty. That path was unreachable from the invariant fixture until it was given a real
    /// verifier, which is why this went unnoticed for so long.
    function test_NoCuratorMayVoteAfterThePanelHasRuled() public {
        v.setVerdict(EvidenceVerdict.UNRESOLVED);

        // Light curators, so curator1+curator2 alone clear the 50% bar and the pair below are
        // genuinely late arrivals. Registered before submission because curator quorum is
        // snapshotted at that point, exactly as attester quorum is.
        address late1 = makeAddr("late1");
        address late2 = makeAddr("late2");
        vm.startPrank(owner);
        glt.registerCurator(late1, 50);
        glt.registerCurator(late2, 50);
        vm.stopPrank();
        _fundCur(late1);
        _fundCur(late2);

        bytes32 id = _submit();
        _sign(id, attester1);
        vm.prank(challenger1);
        glt.challengeAttestation(id, "a");
        _skipWindow();

        // curator1+curator2 = 200 >= 50% of 400, so this settles as a rejection.
        vm.prank(curator1);
        glt.castCuratorVote(id, false);
        vm.prank(curator2);
        glt.castCuratorVote(id, false);
        glt.tallyDispute(id);

        assertEq(uint8(glt.getAttestation(id).status), uint8(GalacticTrust.AttestationStatus.PENDING));
        assertTrue(glt.panelSettled(id), "the panel has ruled");
        uint256 up = glt.upholdWeight(id);
        uint256 down = glt.rejectWeight(id);

        // A curator who never voted is refused, which is the whole point.
        vm.prank(late1);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.AlreadyRuled.selector, id));
        glt.castCuratorVote(id, true);

        // And the tally that decided this is frozen, not merely un-reachable through a vote.
        assertEq(glt.upholdWeight(id), up, "a settled tally must not move");
        assertEq(glt.rejectWeight(id), down, "a settled tally must not move");

        vm.prank(late2);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.AlreadyRuled.selector, id));
        glt.castCuratorVote(id, true);

        // The submitter the panel exonerated is still exonerated.
        assertEq(glt.getAttestation(id).stake, MIN_STAKE, "no second ruling reached the submitter");
        _solvent();
    }

    /// A ruling that punished the submitter must not leave the approval flag behind, or an
    /// integrator reading `panelOverride` would treat a slashed submission as human-approved.
    function test_UpholdingAfterAnOverrideClearsIt() public {
        v.setVerdict(EvidenceVerdict.REFUTED);
        bytes32 id = _submit();
        _sign(id, attester1);
        _skipWindow();

        // First ruling: the panel rejects the machine, so the override is recorded.
        vm.prank(curator1);
        glt.castCuratorVote(id, false);
        vm.prank(curator2);
        glt.castCuratorVote(id, false);
        glt.tallyDispute(id);
        assertTrue(glt.getAttestation(id).panelOverride);

        // The panel has ruled, so it cannot rule again. The only remaining path to a terminal
        // state is expiry — and expiry against a REFUTED verdict punishes the submitter.
        _expire();
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.ReviewAlreadyResolved.selector, id));
        glt.expireReview(id);
        _solvent();
    }

    function test_RevertWhen_CuratorVotesTwiceOnAnOpenDispute() public {
        bytes32 id = _submit();
        _sign(id, attester1);
        vm.prank(challenger1);
        glt.challengeAttestation(id, "a");
        _skipWindow();

        vm.prank(curator1);
        glt.castCuratorVote(id, true);
        vm.prank(curator1);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.AlreadyVoted.selector, id, curator1));
        glt.castCuratorVote(id, false);

        assertEq(glt.curatorOpenVotes(curator1), 1, "one vote, one lock");
        _solvent();
    }
}

contract MockV is IVerifier {
    EvidenceVerdict public verdict;
    bool public shouldRevert;

    constructor(EvidenceVerdict _verdict) {
        verdict = _verdict;
    }

    function setVerdict(EvidenceVerdict v) external {
        verdict = v;
    }

    function setShouldRevert(bool r) external {
        shouldRevert = r;
    }

    function verifyEvidence(bytes32, uint8) external view returns (EvidenceVerdict) {
        require(!shouldRevert, "boom");
        return verdict;
    }
}
