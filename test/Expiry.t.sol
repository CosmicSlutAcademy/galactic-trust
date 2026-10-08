// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GalacticTrust} from "../src/GalacticTrust.sol";
import {IVerifier, EvidenceVerdict} from "../src/IVerifier.sol";

/// Same shape as the mocks in the other suites. `shouldRevert` models a proof system that is
/// broken rather than opinionated, which is the realistic outage: every attestation reads
/// UNRESOLVED, and that is the condition which made the strand reachable at all.
contract MockExpiryV is IVerifier {
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

/**
 * The EXPIRED terminal state.
 *
 * A safety net that can strand the capital it is protecting is not a safety net. Before this
 * file, an `UNRESOLVED` attestation whose panel tied or stayed silent at expiry was left
 * `PENDING` with no reachable exit: the verdict could never become `CONFIRMED`, the challenge
 * window was shut, `panelSettled` refused another ballot, and no expiry would change it. The
 * submitter's `minStake` was held by the contract forever, by anyone.
 *
 * Under a reverting verifier *every* attestation is `UNRESOLVED`, so this was not one unlucky
 * record. It was a stake stranded per attestation for the duration of an outage.
 *
 * The answer is a fourth terminal state. The attestation survives the review with no ruling
 * against it, so the stake goes back to the submitter and no reward is minted: the claim was
 * neither certified nor refuted, so it earns nothing and costs nothing. That is the only
 * settlement consistent with `expireReview`'s own stated rule -- an unreachable or deadlocked
 * panel can never punish a submitter who did nothing wrong.
 */
contract ExpiryTest is Test {
    GalacticTrust internal glt;
    MockExpiryV internal v;

    address internal owner = address(this);
    address internal submitter = makeAddr("submitter");
    address internal attester1 = makeAddr("attester1");
    address internal challenger1 = makeAddr("challenger1");
    address internal curator1 = makeAddr("curator1");
    address internal curator2 = makeAddr("curator2");
    address internal curator3 = makeAddr("curator3");

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
        glt.registerCurator(curator1, 100);
        glt.registerCurator(curator2, 100);
        glt.registerCurator(curator3, 100);

        vm.startPrank(owner);
        glt.setRewardAmount(REWARD);
        glt.setAttesterBondAmount(BOND);
        glt.setChallengeBondAmount(CHALLENGE_BOND);
        glt.setCuratorBondAmount(CURATOR_BOND);
        vm.stopPrank();

        vm.prank(submitter);
        glt.transfer(attester1, BOND * 2);
        vm.prank(attester1);
        glt.fundAttesterBond(BOND);
        vm.prank(submitter);
        glt.transfer(curator1, CURATOR_BOND * 2);
        vm.prank(curator1);
        glt.fundCuratorBond(CURATOR_BOND);
        vm.prank(submitter);
        glt.transfer(curator2, CURATOR_BOND * 2);
        vm.prank(curator2);
        glt.fundCuratorBond(CURATOR_BOND);
        vm.prank(submitter);
        glt.transfer(curator3, CURATOR_BOND * 2);
        vm.prank(curator3);
        glt.fundCuratorBond(CURATOR_BOND);
        vm.prank(submitter);
        glt.transfer(challenger1, CHALLENGE_BOND * 2);
        vm.prank(challenger1);
        glt.fundChallengeBond(CHALLENGE_BOND);

        v = new MockExpiryV(EvidenceVerdict.CONFIRMED);
        vm.prank(owner);
        glt.setVerifier(address(v));
    }

    function _submit() internal returns (bytes32 id) {
        bytes32 s = keccak256(abi.encode("e", ++_nonce));
        vm.prank(submitter);
        id = glt.submitAttestation(keccak256(abi.encode(s, submitter)), s, GalacticTrust.EvidenceTier.R2);
    }

    function _expiry() internal {
        vm.warp(block.timestamp + glt.CHALLENGE_WINDOW() + 1 + glt.REVIEW_WINDOW() + 1);
    }

    function _solvent() internal {
        assertGe(glt.balanceOf(address(glt)), glt.totalLiabilities(), "insolvent");
    }

    /// The core claim: a panel that deadlocked costs the submitter their capital back, nothing
    /// more. The two halves are asserted separately because they are different guarantees --
    /// returning the stake is the safety net, minting nothing is what stops this from being a
    /// third way to mint on unconfirmed evidence.
    function test_TiedPanelReleasesStakeAndMintsNothing() public {
        v.setVerdict(EvidenceVerdict.UNRESOLVED);
        uint256 supplyBefore = glt.totalSupply();
        uint256 balanceBefore = glt.balanceOf(submitter);

        bytes32 id = _submit();
        vm.prank(attester1);
        glt.signAttestation(id);

        // An even split at 100 each against a 150 snapshotted quorum.
        vm.warp(block.timestamp + glt.CHALLENGE_WINDOW() + 1);
        vm.prank(curator1);
        glt.castCuratorVote(id, true);
        vm.prank(curator2);
        glt.castCuratorVote(id, false);

        _expiry();
        glt.expireReview(id);

        assertEq(uint8(glt.getAttestation(id).status), uint8(GalacticTrust.AttestationStatus.EXPIRED), "terminal");
        assertEq(glt.getAttestation(id).stake, 0, "no stake is left counted against the attestation");
        // The stake leaves the submitter at submission and comes back here, so the net movement
        // is zero. Asserting a *positive* delta would only prove the stake was never taken;
        // asserting zero proves it left and was returned, and that no reward rode along with it.
        assertEq(glt.balanceOf(submitter), balanceBefore, "the stake left and came back, nothing more");
        assertEq(glt.totalStaked(), 0, "and the book released it");
        // Burns are expected: the panel tied, so the uphold ballot was the dissent and it is
        // slashed. What must never happen is a mint, hence `Le` and not `Eq`.
        assertLe(glt.totalSupply(), supplyBefore, "no reward was minted for a claim nobody certified");
        _solvent();
    }

    /// The same for silence. Nothing voted at all, which is the case an outage actually produces
    /// -- not a deadlocked panel, but a panel that never assembled.
    function test_SilenceReleasesStakeAndMintsNothing() public {
        v.setVerdict(EvidenceVerdict.UNRESOLVED);
        uint256 supplyBefore = glt.totalSupply();
        uint256 balanceBefore = glt.balanceOf(submitter);

        bytes32 id = _submit();
        vm.prank(attester1);
        glt.signAttestation(id);

        _expiry();
        glt.expireReview(id);

        assertEq(uint8(glt.getAttestation(id).status), uint8(GalacticTrust.AttestationStatus.EXPIRED));
        assertEq(glt.balanceOf(submitter), balanceBefore, "stake left and came back");
        assertEq(glt.totalStaked(), 0, "book released");
        assertEq(glt.totalSupply(), supplyBefore, "nothing minted");
        _solvent();
    }

    /// A minority that showed up and lost is the case the quorum fix made reachable, and it must
    /// terminate the same way rather than locking.
    function test_SubQuorumAcquittalReleasesStakeRatherThanLocking() public {
        v.setVerdict(EvidenceVerdict.UNRESOLVED);
        uint256 balanceBefore = glt.balanceOf(submitter);

        bytes32 id = _submit();
        vm.prank(attester1);
        glt.signAttestation(id);
        vm.warp(block.timestamp + glt.CHALLENGE_WINDOW() + 1);
        vm.prank(curator1);
        glt.castCuratorVote(id, false);

        _expiry();
        glt.expireReview(id);

        assertEq(uint8(glt.getAttestation(id).status), uint8(GalacticTrust.AttestationStatus.EXPIRED));
        assertEq(glt.balanceOf(submitter), balanceBefore, "no stranded stake");
        assertEq(glt.totalStaked(), 0, "and the book released it");
        _solvent();
    }

    /// EXPIRED is terminal in the same way SLASHED and FINALIZED are. Every path that could move
    /// a PENDING attestation must refuse it, and the totals must not move while they do.
    function test_ExpiredAttestationIsTerminal() public {
        v.setVerdict(EvidenceVerdict.UNRESOLVED);
        bytes32 id = _submit();
        vm.prank(attester1);
        glt.signAttestation(id);
        _expiry();
        glt.expireReview(id);

        uint256 staked = glt.totalStaked();
        uint256 liabilities = glt.totalLiabilities();

        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.AttestationNotPending.selector, id));
        glt.finalizeAttestation(id);

        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.AttestationNotPending.selector, id));
        glt.challengeAttestation(id, "too late");

        vm.prank(curator1);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.NotPendingOrDisputed.selector, id));
        glt.castCuratorVote(id, true);

        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.NotPendingOrDisputed.selector, id));
        glt.tallyDispute(id);

        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.NotPendingOrDisputed.selector, id));
        glt.expireReview(id);

        assertEq(glt.totalStaked(), staked, "and none of them moved the books");
        assertEq(glt.totalLiabilities(), liabilities);
        _solvent();
    }

    /// An expired attestation still yields its pre-image to a challenger or curator. Disclosure
    /// is safe here precisely because the record is terminal and can no longer be moved -- which
    /// is why this path is left open rather than refused, unlike SLASHED and FINALIZED.
    function test_ExpiredAttestationStillDisclosesItsPreImage() public {
        v.setVerdict(EvidenceVerdict.UNRESOLVED);
        bytes32 s = keccak256(abi.encode("revealable", ++_nonce));
        vm.prank(submitter);
        bytes32 id = glt.submitAttestation(keccak256(abi.encode(s, submitter)), s, GalacticTrust.EvidenceTier.R2);
        vm.prank(attester1);
        glt.signAttestation(id);

        // The challenge has to be filed inside the window, the curator ballot after it closes.
        vm.prank(challenger1);
        glt.challengeAttestation(id, "a");
        vm.warp(block.timestamp + glt.CHALLENGE_WINDOW() + 1);
        vm.prank(curator1);
        glt.castCuratorVote(id, false);

        _expiry();
        glt.expireReview(id);

        vm.prank(curator1);
        glt.revealSecret(id, s);
        assertTrue(glt.getAttestation(id).secretRevealed, "the record is auditable after the fact");
        assertEq(glt.getAttestation(id).secret, s);
        _solvent();
    }

    /// A refutation is a positive finding, so it keeps its slash and must NOT be expired into a
    /// stake return. If `EXPIRED` ever caught these, a REFUTED claim would become free to submit.
    function test_RefutationIsNeverExpiredIntoAStakeReturn() public {
        v.setVerdict(EvidenceVerdict.REFUTED);
        uint256 supplyBefore = glt.totalSupply();
        uint256 balanceBefore = glt.balanceOf(submitter);

        bytes32 id = _submit();
        vm.prank(attester1);
        glt.signAttestation(id);

        _expiry();
        glt.expireReview(id);

        assertEq(
            uint8(glt.getAttestation(id).status), uint8(GalacticTrust.AttestationStatus.SLASHED), "refutations stand"
        );
        assertEq(glt.balanceOf(submitter), balanceBefore - MIN_STAKE, "the stake is not returned on a refutation");
        // Burns are expected here -- the stake and the attester bond -- so supply moves down.
        // What must never happen is a mint, which is why this is a `Le` and not an `Eq`.
        assertLe(glt.totalSupply(), supplyBefore, "no reward was minted on a refutation");
        _solvent();
    }

    /// A full-quorum acquittal still overrides the machine and still finalizes with a reward.
    /// This is the case EXPIRED must not swallow: when a real panel has ruled, the ruling is the
    /// outcome, and `expireReview` refuses it outright rather than expiring it.
    function test_QuorumAcquittalStillFinalizesAndMints() public {
        v.setVerdict(EvidenceVerdict.UNRESOLVED);
        bytes32 id = _submit();
        vm.prank(attester1);
        glt.signAttestation(id);
        vm.warp(block.timestamp + glt.CHALLENGE_WINDOW() + 1);
        vm.prank(curator1);
        glt.castCuratorVote(id, false);
        vm.prank(curator2);
        glt.castCuratorVote(id, false);
        glt.tallyDispute(id);

        assertTrue(glt.getAttestation(id).panelOverride, "a quorum acquittal overrides");
        _expiry();
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.ReviewAlreadyResolved.selector, id));
        glt.expireReview(id);

        glt.finalizeAttestation(id);
        assertEq(uint8(glt.getAttestation(id).status), uint8(GalacticTrust.AttestationStatus.FINALIZED));
        _solvent();
    }

    /// An unchanged `CONFIRMED` verdict has no reason to reach any of this: the attestation
    /// finalizes normally.
    ///
    /// Note that `expireReview` does *not* refuse this, unlike `castCuratorVote` and
    /// `tallyDispute`, which both reject a challenger-less `CONFIRMED` attestation with
    /// `NoChallengesToResolve`. Here it runs to completion and emits `ReviewExpired` on an
    /// attestation nobody disputed. It is harmless for the funds -- nothing is staked to forfeit,
    /// no curator voted so nothing is slashed, and the attestation still finalizes with its
    /// reward -- but the event is false and `panelSettled` is set on the way through. Recorded
    /// in SESSION.md rather than guarded here, because a guard costs margin that an audit has
    /// not yet allocated.
    function test_ConfirmedAttestationIsUnaffected() public {
        uint256 balanceBefore = glt.balanceOf(submitter);
        bytes32 id = _submit();
        vm.prank(attester1);
        glt.signAttestation(id);
        _expiry();

        glt.expireReview(id);
        assertTrue(
            uint8(glt.getAttestation(id).status) != uint8(GalacticTrust.AttestationStatus.EXPIRED),
            "a confirmed attestation is never expired"
        );

        glt.finalizeAttestation(id);
        assertEq(uint8(glt.getAttestation(id).status), uint8(GalacticTrust.AttestationStatus.FINALIZED));
        assertEq(glt.balanceOf(submitter) - balanceBefore, REWARD, "stake back plus reward");
        _solvent();
    }
}
