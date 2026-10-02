// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GalacticTrust} from "../src/GalacticTrust.sol";
import {IVerifier, EvidenceVerdict} from "../src/IVerifier.sol";

/// @dev Switchable tri-state verifier. `shouldRevert` models a broken proof system, which must
/// degrade to UNRESOLVED rather than halting the protocol.
contract MockVerifier is IVerifier {
    EvidenceVerdict public verdict;
    bool public shouldRevert;

    constructor(EvidenceVerdict _verdict) {
        verdict = _verdict;
    }

    function setVerdict(EvidenceVerdict _verdict) external {
        verdict = _verdict;
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function verifyEvidence(bytes32, uint8) external view returns (EvidenceVerdict) {
        require(!shouldRevert, "verifier exploded");
        return verdict;
    }
}

contract GalacticTrustTest is Test {
    GalacticTrust internal glt;
    MockVerifier internal verifier;

    address internal owner = address(this);
    address internal submitter = makeAddr("submitter");
    address internal attester1 = makeAddr("attester1");
    address internal attester2 = makeAddr("attester2");
    address internal attester3 = makeAddr("attester3");
    address internal challenger = makeAddr("challenger");
    address internal outsider = makeAddr("outsider");
    address internal curator1 = makeAddr("curator1");
    address internal curator2 = makeAddr("curator2");
    address internal curator3 = makeAddr("curator3");

    bytes32 internal constant SECRET = keccak256("r5-confirmed-intel");
    bytes32 contentHash;
    uint256 internal constant MIN_STAKE = 1_000e18;
    uint256 internal constant BOND = 5_000e18;
    uint256 internal constant REWARD = 100e18;
    uint256 internal constant TREASURY = 1_000_000e18;
    uint256 internal constant CHALLENGE_BOND = 100e18;
    uint256 internal constant CURATOR_BOND = 1_000e18;

    function setUp() public {
        glt = new GalacticTrust(owner, MIN_STAKE, address(0), TREASURY, submitter);
        glt.registerAttester(attester1, 100);
        glt.registerAttester(attester2, 100);
        glt.registerAttester(attester3, 100);
        glt.registerCurator(curator1, 100);
        glt.registerCurator(curator2, 100);
        glt.registerCurator(curator3, 100);
        contentHash = keccak256(abi.encode(SECRET, submitter));

        assertEq(glt.totalLiabilities(), glt.balanceOf(address(glt)), "fresh contract owes exactly what it holds");

        vm.startPrank(owner);
        glt.setRewardAmount(REWARD);
        glt.setAttesterBondAmount(BOND);
        glt.setChallengeBondAmount(CHALLENGE_BOND);
        glt.setCuratorBondAmount(CURATOR_BOND);
        vm.stopPrank();

        _fund(attester1);
        _fund(attester2);
        _fund(attester3);
        _fundChallenger(challenger);
        _fundChallenger(outsider);
        _fundCurator(curator1);
        _fundCurator(curator2);
        _fundCurator(curator3);
    }

    /// @dev Funds attesters from the treasury. No test-only mint exists in the token on purpose.
    function _fund(address who) internal {
        vm.prank(submitter);
        glt.transfer(who, BOND * 2);
        vm.prank(who);
        glt.fundAttesterBond(BOND);
    }

    function _fundChallenger(address who) internal {
        vm.prank(submitter);
        glt.transfer(who, CHALLENGE_BOND * 2);
        vm.prank(who);
        glt.fundChallengeBond(CHALLENGE_BOND);
    }

    /// @dev A curatorship is only meaningful with skin behind it, so every curator in these
    /// tests is bonded. An unbonded curator cannot cast a weight-bearing vote at all.
    function _fundCurator(address who) internal {
        vm.prank(submitter);
        glt.transfer(who, CURATOR_BOND * 2);
        vm.prank(who);
        glt.fundCuratorBond(CURATOR_BOND);
    }

    /// @dev The invariant that makes every other assertion here meaningful: the contract
    /// never owes more than it holds, and never holds more than it owes beyond dust.
    function _assertSolvent() internal {
        assertGe(glt.balanceOf(address(glt)), glt.totalLiabilities(), "contract owes more than it holds");
    }

    /// @dev Two of three curators uphold, which clears the 50% curator quorum.
    function _resolveUp(bytes32 id) internal {
        _skipWindow();
        vm.prank(curator1);
        glt.castCuratorVote(id, true);
        vm.prank(curator2);
        glt.castCuratorVote(id, true);
        glt.tallyDispute(id);
    }

    /// @dev Two of three curators reject, so the challenge is thrown out.
    function _resolveDown(bytes32 id) internal {
        _skipWindow();
        vm.prank(curator1);
        glt.castCuratorVote(id, false);
        vm.prank(curator2);
        glt.castCuratorVote(id, false);
        glt.tallyDispute(id);
    }

    /// @dev An even split with quorum met. Stalls the dispute rather than guessing.
    function _resolveSplit(bytes32 id) internal {
        _skipWindow();
        vm.prank(curator1);
        glt.castCuratorVote(id, true);
        vm.prank(curator2);
        glt.castCuratorVote(id, false);
    }

    function _submit() internal returns (bytes32 id) {
        vm.prank(submitter);
        id = glt.submitAttestation(contentHash, SECRET, GalacticTrust.EvidenceTier.R2);
    }

    /// @dev A distinct secret per call. `submitAttestation` derives the id from
    /// (submitter, contentHash, timestamp, secret), and Foundry does not advance the block
    /// timestamp between calls, so reusing SECRET would collide and overwrite the record.
    function _submitDistinct(bytes32 secret) internal returns (bytes32 id) {
        vm.prank(submitter);
        id = glt.submitAttestation(keccak256(abi.encode(secret, submitter)), secret, GalacticTrust.EvidenceTier.R2);
    }

    function _skipWindow() internal {
        vm.warp(block.timestamp + glt.CHALLENGE_WINDOW() + 1);
    }

    /// @dev Two signers clear the 150 quorum with 200 weight.
    function _signTwo(bytes32 id) internal {
        vm.startPrank(attester1);
        glt.signAttestation(id);
        vm.stopPrank();
        vm.prank(attester2);
        glt.signAttestation(id);
    }

    /// @dev A referral ruling: two of three curators uphold, so a REFUTED/UNRESOLVED verdict
    /// becomes a slash even though no one challenged.
    function _upholdReferral(bytes32 id) internal {
        _skipWindow();
        vm.prank(curator1);
        glt.castCuratorVote(id, true);
        vm.prank(curator2);
        glt.castCuratorVote(id, true);
        glt.tallyDispute(id);
    }

    /// @dev The humans overrule the machine. Recorded as `panelOverride`.
    function _rejectReferral(bytes32 id) internal {
        _skipWindow();
        vm.prank(curator1);
        glt.castCuratorVote(id, false);
        vm.prank(curator2);
        glt.castCuratorVote(id, false);
        glt.tallyDispute(id);
    }

    // ---------- registry ----------

    function test_QuorumIsHalfOfTotalWeight() public view {
        assertEq(glt.totalAttesterWeight(), 300);
        assertEq(glt.requiredQuorumWeight(), 150);
    }

    function test_RevertWhen_RegisterZeroAddress() public {
        vm.expectRevert(GalacticTrust.ZeroAddress.selector);
        glt.registerAttester(address(0), 10);
    }

    function test_DeactivateAttesterDropsWeight() public {
        vm.prank(owner);
        glt.deactivateAttester(attester1);
        assertEq(glt.totalAttesterWeight(), 200);
        assertEq(glt.requiredQuorumWeight(), 100);
    }

    // ---------- submission ----------

    function test_SubmitLocksStakeAndOpensWindow() public {
        bytes32 id = _submit();
        GalacticTrust.Attestation memory att = glt.getAttestation(id);
        assertEq(uint8(att.status), uint8(GalacticTrust.AttestationStatus.PENDING));
        assertEq(att.stake, MIN_STAKE);
        assertEq(
            glt.balanceOf(address(glt)),
            BOND * 3 + CHALLENGE_BOND * 2 + CURATOR_BOND * 3 + MIN_STAKE,
            "bonds + challenge bonds + curator bonds + stake"
        );
        assertEq(att.challengeDeadline, block.timestamp + glt.CHALLENGE_WINDOW());
    }

    function test_RevertWhen_SubmitBelowMinStake() public {
        address poor = makeAddr("poor");
        vm.prank(poor);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.InsufficientStake.selector, 0, MIN_STAKE));
        glt.submitAttestation(contentHash, SECRET, GalacticTrust.EvidenceTier.R1);
    }

    function test_RevertWhen_SubmitUnverifiedTier() public {
        vm.prank(submitter);
        vm.expectRevert(GalacticTrust.TierOutOfRange.selector);
        glt.submitAttestation(contentHash, SECRET, GalacticTrust.EvidenceTier.UNVERIFIED);
    }

    // ---------- signing ----------

    function test_RevertWhen_SignerNotAttester() public {
        bytes32 id = _submit();
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.NotAttester.selector, outsider));
        glt.signAttestation(id);
    }

    function test_RevertWhen_DoubleSign() public {
        bytes32 id = _submit();
        vm.prank(attester1);
        glt.signAttestation(id);
        vm.prank(attester1);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.AlreadyAttested.selector, id, attester1));
        glt.signAttestation(id);
    }

    function test_SignAccumulatesWeight() public {
        bytes32 id = _submit();
        vm.startPrank(attester1);
        glt.signAttestation(id);
        vm.stopPrank();
        vm.prank(attester2);
        glt.signAttestation(id);
        assertEq(glt.getAttestation(id).attestationWeight, 200);
        assertEq(glt.signerWeight(id), 200);
    }

    function test_RevertWhen_SignerHasNoBond() public {
        bytes32 id = _submit();
        address unbonded = makeAddr("unbonded");
        vm.prank(owner);
        glt.registerAttester(unbonded, 100);
        vm.prank(unbonded);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.BondBelowRequired.selector, 0, BOND));
        glt.signAttestation(id);
    }

    function test_RevertWhen_BondUnderfunded() public {
        vm.prank(attester1);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.InsufficientStake.selector, BOND, BOND * 2));
        glt.fundAttesterBond(BOND * 2);
    }

    function test_RevertWhen_WithdrawWhileActive() public {
        vm.prank(attester1);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.AttesterStillActive.selector, attester1));
        glt.withdrawAttesterBond();
    }

    function test_DeactivatedAttesterCanWithdrawBond() public {
        vm.prank(owner);
        glt.deactivateAttester(attester1);
        uint256 balBefore = glt.balanceOf(attester1);
        vm.prank(attester1);
        glt.withdrawAttesterBond();
        assertEq(glt.balanceOf(attester1), balBefore + BOND);
        assertEq(glt.attesterBond(attester1), 0);
    }

    function test_RevertWhen_WithdrawTwice() public {
        vm.prank(owner);
        glt.deactivateAttester(attester1);
        vm.prank(attester1);
        glt.withdrawAttesterBond();
        vm.prank(attester1);
        vm.expectRevert(GalacticTrust.NoBondToWithdraw.selector);
        glt.withdrawAttesterBond();
    }

    // ---------- finalization ----------

    function test_RevertWhen_FinalizeBeforeWindowCloses() public {
        bytes32 id = _submit();
        vm.startPrank(attester1);
        glt.signAttestation(id);
        vm.stopPrank();
        vm.prank(attester2);
        glt.signAttestation(id);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.ChallengeWindowOpen.selector, id));
        glt.finalizeAttestation(id);
    }

    function test_RevertWhen_FinalizeWithoutQuorum() public {
        bytes32 id = _submit();
        vm.prank(attester1);
        glt.signAttestation(id);
        _skipWindow();
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.QuorumNotReached.selector, id, 100, 150));
        glt.finalizeAttestation(id);
    }

    function test_FinalizeMintsRewardAndReturnsStake() public {
        bytes32 id = _submit();
        uint256 before = glt.balanceOf(submitter);
        vm.startPrank(attester1);
        glt.signAttestation(id);
        vm.stopPrank();
        vm.prank(attester2);
        glt.signAttestation(id);
        _skipWindow();
        glt.finalizeAttestation(id);

        assertEq(uint8(glt.getAttestation(id).status), uint8(GalacticTrust.AttestationStatus.FINALIZED));
        assertEq(glt.balanceOf(submitter), before + MIN_STAKE + REWARD, "stake returned + reward minted");
        assertEq(
            glt.balanceOf(address(glt)),
            BOND * 3 + CHALLENGE_BOND * 2 + CURATOR_BOND * 3,
            "attester + challenge + curator bonds remain"
        );
    }

    function test_RevertWhen_DoubleFinalize() public {
        bytes32 id = _submit();
        vm.startPrank(attester1);
        glt.signAttestation(id);
        vm.stopPrank();
        vm.prank(attester2);
        glt.signAttestation(id);
        _skipWindow();
        glt.finalizeAttestation(id);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.QuorumReached.selector, id));
        glt.finalizeAttestation(id);
    }

    // ---------- challenge + slash ----------

    function test_RevertWhen_ChallengeAfterWindow() public {
        bytes32 id = _submit();
        _skipWindow();
        vm.prank(challenger);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.ChallengeWindowClosed.selector, id));
        glt.challengeAttestation(id, "too late");
    }

    function test_RevertWhen_DoubleChallenge() public {
        bytes32 id = _submit();
        vm.prank(challenger);
        glt.challengeAttestation(id, "first");
        vm.prank(challenger);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.AlreadyChallenged.selector, id, challenger));
        glt.challengeAttestation(id, "second");
    }

    function test_ChallengeBlocksFinalizeEvenWithQuorum() public {
        bytes32 id = _submit();
        vm.startPrank(attester1);
        glt.signAttestation(id);
        vm.stopPrank();
        vm.prank(attester2);
        glt.signAttestation(id);
        vm.prank(challenger);
        glt.challengeAttestation(id, "fabricated");
        _skipWindow();
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.AttestationUnderChallenge.selector, id));
        glt.finalizeAttestation(id);
    }

    function test_ChallengeDoesNotFreezeSignatures() public {
        bytes32 id = _submit();
        vm.prank(challenger);
        glt.challengeAttestation(id, "fabricated");
        assertEq(
            uint8(glt.getAttestation(id).status),
            uint8(GalacticTrust.AttestationStatus.PENDING),
            "one challenger must not escalate alone"
        );
        vm.prank(attester1);
        glt.signAttestation(id);
    }

    function test_UpheldDisputeSlashesStake() public {
        bytes32 id = _submit();
        vm.prank(challenger);
        glt.challengeAttestation(id, "fabricated");
        uint256 supplyBefore = glt.totalSupply();
        _resolveUp(id);

        GalacticTrust.Attestation memory att = glt.getAttestation(id);
        assertEq(uint8(att.status), uint8(GalacticTrust.AttestationStatus.SLASHED));
        assertEq(att.stake, 0, "stake fully consumed");
        assertEq(glt.totalSupply(), supplyBefore - MIN_STAKE, "submitter stake burned, no reward");
    }

    function test_UpheldDisputeSlashesSigningAttesters() public {
        bytes32 id = _submit();
        vm.startPrank(attester1);
        glt.signAttestation(id);
        vm.stopPrank();
        vm.prank(attester2);
        glt.signAttestation(id);
        vm.prank(challenger);
        glt.challengeAttestation(id, "fabricated");
        uint256 supplyBefore = glt.totalSupply();
        _resolveUp(id);

        assertEq(glt.attesterBond(attester1), 0, "signer bond slashed");
        assertEq(glt.attesterBond(attester2), 0, "signer bond slashed");
        assertEq(glt.totalSupply(), supplyBefore - MIN_STAKE - (BOND * 2), "submitter stake + both signer bonds burned");
    }

    function test_NonSigningAttesterKeepsBond() public {
        bytes32 id = _submit();
        vm.startPrank(attester1);
        glt.signAttestation(id);
        vm.stopPrank();
        vm.prank(attester2);
        glt.signAttestation(id);
        vm.prank(challenger);
        glt.challengeAttestation(id, "fabricated");
        _resolveUp(id);

        assertEq(glt.attesterBond(attester3), BOND, "innocent attester untouched");
    }

    function test_PartialSlashSeedsPullPaymentPool() public {
        vm.prank(owner);
        glt.setSlashBps(5_000);
        bytes32 id = _submit();
        vm.prank(challenger);
        glt.challengeAttestation(id, "fabricated");
        _resolveUp(id);

        uint256 expected = MIN_STAKE / 2 + CHALLENGE_BOND;
        assertEq(glt.payoutPool(id), expected, "unburned remainder + forfeited bond escrowed");
        uint256 balBefore = glt.balanceOf(challenger);
        vm.prank(challenger);
        glt.claimChallengeReward(id);
        assertEq(glt.balanceOf(challenger), balBefore + expected, "challenger paid on pull");
    }

    function test_RejectedDisputeLeavesBondsIntact() public {
        bytes32 id = _submit();
        vm.prank(attester1);
        glt.signAttestation(id);
        vm.prank(challenger);
        glt.challengeAttestation(id, "wrong call");
        _resolveDown(id);
        assertEq(glt.attesterBond(attester1), BOND, "no slash on a rejected dispute");
    }

    function test_RejectedDisputeForfeitsChallengeBond() public {
        bytes32 id = _submit();
        vm.prank(attester1);
        glt.signAttestation(id);
        vm.prank(challenger);
        glt.challengeAttestation(id, "wrong call");
        _resolveDown(id);
        assertEq(glt.challengeBond(challenger), 0, "frivolous challenge forfeits its bond");
    }

    function test_RejectedDisputeReopensAndCanFinalize() public {
        bytes32 id = _submit();
        vm.startPrank(attester1);
        glt.signAttestation(id);
        vm.stopPrank();
        vm.prank(attester2);
        glt.signAttestation(id);
        vm.prank(challenger);
        glt.challengeAttestation(id, "wrong call");
        _resolveDown(id);
        assertEq(uint8(glt.getAttestation(id).status), uint8(GalacticTrust.AttestationStatus.PENDING));

        glt.finalizeAttestation(id);
        assertEq(uint8(glt.getAttestation(id).status), uint8(GalacticTrust.AttestationStatus.FINALIZED));
    }

    // ---------- curator panel ----------

    function test_OneCuratorCannotDecideAlone() public {
        bytes32 id = _submit();
        vm.prank(challenger);
        glt.challengeAttestation(id, "fabricated");
        _skipWindow();
        vm.prank(curator1);
        glt.castCuratorVote(id, true);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.CuratorQuorumNotReached.selector, id, 100, 150));
        glt.tallyDispute(id);
    }

    function test_RevertWhen_CuratorSplitNoMajority() public {
        bytes32 id = _submit();
        vm.prank(challenger);
        glt.challengeAttestation(id, "fabricated");
        _resolveSplit(id);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.CuratorsSplit.selector, id, 100, 100));
        glt.tallyDispute(id);
    }

    function test_RevertWhen_DoubleCuratorVote() public {
        bytes32 id = _submit();
        vm.prank(challenger);
        glt.challengeAttestation(id, "x");
        _skipWindow();
        vm.prank(curator1);
        glt.castCuratorVote(id, true);
        vm.prank(curator1);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.AlreadyVoted.selector, id, curator1));
        glt.castCuratorVote(id, true);
    }

    function test_RevertWhen_NonCuratorVotes() public {
        bytes32 id = _submit();
        vm.prank(challenger);
        glt.challengeAttestation(id, "x");
        _skipWindow();
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.NotCurator.selector, outsider));
        glt.castCuratorVote(id, true);
    }

    function test_RevertWhen_VoteBeforeWindowCloses() public {
        bytes32 id = _submit();
        vm.prank(challenger);
        glt.challengeAttestation(id, "x");
        vm.prank(curator1);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.CuratorVoteTooEarly.selector, id));
        glt.castCuratorVote(id, true);
    }

    function test_RevertWhen_VoteWithNoChallenges() public {
        bytes32 id = _submit();
        _skipWindow();
        vm.prank(curator1);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.NoChallengesToResolve.selector, id));
        glt.castCuratorVote(id, true);
    }

    function test_OwnerCannotOverrideCurators() public {
        bytes32 id = _submit();
        vm.prank(challenger);
        glt.challengeAttestation(id, "x");
        _skipWindow();
        vm.prank(owner);
        vm.expectRevert();
        glt.castCuratorVote(id, true);
    }

    // ---------- caps ----------

    function test_RevertWhen_SignerCapReached() public {
        bytes32 id = _submit();
        uint256 n = glt.MAX_SIGNERS();
        for (uint256 i = 0; i < n; i++) {
            address a = address(uint160(0x1000 + i));
            vm.prank(owner);
            glt.registerAttester(a, 1);
            vm.prank(submitter);
            glt.transfer(a, BOND);
            vm.prank(a);
            glt.fundAttesterBond(BOND);
            vm.prank(a);
            glt.signAttestation(id);
        }
        address overflow = address(uint160(0x9999));
        vm.prank(owner);
        glt.registerAttester(overflow, 1);
        vm.prank(submitter);
        glt.transfer(overflow, BOND);
        vm.prank(overflow);
        glt.fundAttesterBond(BOND);
        vm.prank(overflow);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.TooManySigners.selector, id));
        glt.signAttestation(id);
    }

    function test_RevertWhen_ChallengerCapReached() public {
        bytes32 id = _submit();
        uint256 n = glt.MAX_CHALLENGERS();
        for (uint256 i = 0; i < n; i++) {
            address a = address(uint160(0x2000 + i));
            _fundChallenger(a);
            vm.prank(a);
            glt.challengeAttestation(id, "spam");
        }
        address overflow = address(uint160(0x8888));
        _fundChallenger(overflow);
        vm.prank(overflow);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.TooManyChallengers.selector, id));
        glt.challengeAttestation(id, "one too many");
    }

    // ---------- challenge bonds ----------

    function test_RevertWhen_ChallengeWithoutBond() public {
        bytes32 id = _submit();
        address unbonded = makeAddr("unbonded-challenger");
        vm.prank(unbonded);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.BondBelowRequired.selector, 0, CHALLENGE_BOND));
        glt.challengeAttestation(id, "free challenge");
    }

    function test_RevertWhen_ClaimTwice() public {
        bytes32 id = _submit();
        vm.prank(challenger);
        glt.challengeAttestation(id, "fabricated");
        _resolveUp(id);
        vm.prank(challenger);
        glt.claimChallengeReward(id);
        vm.prank(challenger);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.ClaimAlreadyMade.selector, id, challenger));
        glt.claimChallengeReward(id);
    }

    function test_RevertWhen_ClaimOnRejectedDispute() public {
        bytes32 id = _submit();
        vm.prank(attester1);
        glt.signAttestation(id);
        vm.prank(challenger);
        glt.challengeAttestation(id, "wrong call");
        _resolveDown(id);
        vm.prank(challenger);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.NothingToClaim.selector, id, challenger));
        glt.claimChallengeReward(id);
    }

    function test_RevertWhen_NonChallengerClaims() public {
        bytes32 id = _submit();
        vm.prank(challenger);
        glt.challengeAttestation(id, "fabricated");
        _resolveUp(id);
        uint256 balBefore = glt.balanceOf(outsider);
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.NotAChallenger.selector, id, outsider));
        glt.claimChallengeReward(id);
        assertEq(glt.balanceOf(outsider), balBefore, "outsider cannot drain the pool");
        assertEq(glt.payoutPool(id), CHALLENGE_BOND, "pool intact after failed claim");
    }

    function test_MultipleChallengersAllRecorded() public {
        bytes32 id = _submit();
        vm.prank(challenger);
        glt.challengeAttestation(id, "a");
        vm.prank(outsider);
        glt.challengeAttestation(id, "b");
        assertEq(glt.challengeCount(id), 2, "challenger list accumulates");
        assertEq(glt.signerWeight(id), 0, "no signatures yet");
    }

    // ---------- tri-state evidence gate ----------

    /// @dev Registers a verifier with the given verdict and returns it.
    function _setVerdict(EvidenceVerdict v) internal returns (MockVerifier) {
        MockVerifier mockV = new MockVerifier(v);
        vm.prank(owner);
        glt.setVerifier(address(mockV));
        return mockV;
    }

    function test_VerdictIsConfirmedWhenNoVerifierSet() public {
        bytes32 id = _submit();
        assertEq(
            uint8(glt.evidenceVerdict(id)),
            uint8(EvidenceVerdict.CONFIRMED),
            "no verifier means no objection, not a block"
        );
        _signTwo(id);
        _skipWindow();
        glt.finalizeAttestation(id);
    }

    function test_ConfirmedVerdictFinalizes() public {
        _setVerdict(EvidenceVerdict.CONFIRMED);
        bytes32 id = _submit();
        _signTwo(id);
        _skipWindow();
        glt.finalizeAttestation(id);
        assertEq(uint8(glt.getAttestation(id).status), uint8(GalacticTrust.AttestationStatus.FINALIZED));
        _assertSolvent();
    }

    function test_RevertWhen_RefutedVerdictFinalizes() public {
        _setVerdict(EvidenceVerdict.REFUTED);
        bytes32 id = _submit();
        _signTwo(id);
        _skipWindow();
        vm.expectRevert(
            abi.encodeWithSelector(GalacticTrust.EvidenceNotFinalizable.selector, id, uint8(EvidenceVerdict.REFUTED))
        );
        glt.finalizeAttestation(id);
        _assertSolvent();
    }

    /// The core failsafe: a broken verifier must not halt the protocol, and must not silently
    /// mint either. UNRESOLVED routes to humans and nothing else.
    function test_UnresolvedVerdictRoutesToPanelAndDoesNotMint() public {
        _setVerdict(EvidenceVerdict.UNRESOLVED);
        bytes32 id = _submit();
        _signTwo(id);
        _skipWindow();

        vm.expectRevert(
            abi.encodeWithSelector(GalacticTrust.EvidenceNotFinalizable.selector, id, uint8(EvidenceVerdict.UNRESOLVED))
        );
        glt.finalizeAttestation(id);

        uint256 supplyBefore = glt.totalSupply();
        _rejectReferral(id);
        glt.finalizeAttestation(id);
        assertEq(glt.totalSupply(), supplyBefore + REWARD, "mints only after a human ruling");
        _assertSolvent();
    }

    function test_RevertingVerifierDegradesToUnresolvedRatherThanHalting() public {
        MockVerifier mockV = _setVerdict(EvidenceVerdict.CONFIRMED);
        bytes32 id = _submit();
        _signTwo(id);
        mockV.setShouldRevert(true);

        // must not revert: a broken proof system cannot be allowed to freeze everything
        assertEq(uint8(glt.evidenceVerdict(id)), uint8(EvidenceVerdict.UNRESOLVED));
        _skipWindow();
        vm.expectRevert(
            abi.encodeWithSelector(GalacticTrust.EvidenceNotFinalizable.selector, id, uint8(EvidenceVerdict.UNRESOLVED))
        );
        glt.finalizeAttestation(id);
    }

    /// A referral needs no challenger. Without this the tri-state gate has no exit for a
    /// REFUTED verdict, because nothing can challenge and nothing can finalize.
    function test_RefutedAttestationCanBeReviewedWithNoChallenger() public {
        _setVerdict(EvidenceVerdict.REFUTED);
        bytes32 id = _submit();
        _signTwo(id);
        _skipWindow();
        assertEq(glt.challengeCount(id), 0, "no challenger needed");

        _upholdReferral(id);
        assertEq(uint8(glt.getAttestation(id).status), uint8(GalacticTrust.AttestationStatus.SLASHED));
        assertEq(glt.attesterBond(attester1), 0, "signers slashed on a upheld referral");
        assertEq(glt.attesterBond(attester2), 0, "signers slashed on a upheld referral");
        _assertSolvent();
    }

    /// A panel may deliberately overrule a REFUTED machine verdict. That is a human decision
    /// and it is recorded, not silent.
    function test_PanelMayOverrideRefutedVerdict() public {
        _setVerdict(EvidenceVerdict.REFUTED);
        bytes32 id = _submit();
        _signTwo(id);
        _skipWindow();
        _rejectReferral(id);

        assertTrue(glt.getAttestation(id).panelOverride, "override recorded on-chain");
        uint256 before = glt.balanceOf(submitter);
        glt.finalizeAttestation(id);
        assertEq(glt.balanceOf(submitter), before + MIN_STAKE + REWARD, "finalizes after override");
    }

    function test_NoChallengesAndConfirmedStillReverts() public {
        bytes32 id = _submit();
        _skipWindow();
        vm.prank(curator1);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.NoChallengesToResolve.selector, id));
        glt.castCuratorVote(id, true);
        _assertSolvent();
    }

    // ---------- curator quorum snapshot (bug 7) ----------

    function test_OwnerCannotRaiseQuorumMidDispute() public {
        bytes32 id = _submit();
        assertEq(glt.getAttestation(id).curatorQuorumWeight, 150, "snapshotted at submission");

        vm.prank(challenger);
        glt.challengeAttestation(id, "a");
        _skipWindow();

        // appoint a whale curator after the dispute is filed
        vm.prank(owner);
        glt.registerCurator(makeAddr("whale"), 100_000);
        assertEq(glt.getAttestation(id).curatorQuorumWeight, 150, "snapshot is immune");

        vm.prank(curator1);
        glt.castCuratorVote(id, true);
        vm.prank(curator2);
        glt.castCuratorVote(id, true);
        glt.tallyDispute(id);
        assertEq(uint8(glt.getAttestation(id).status), uint8(GalacticTrust.AttestationStatus.SLASHED));
        _assertSolvent();
    }

    function test_RevertWhen_TallyUsesLiveQuorum() public {
        bytes32 id = _submit();
        vm.prank(challenger);
        glt.challengeAttestation(id, "a");
        _skipWindow();
        vm.prank(owner);
        glt.registerCurator(makeAddr("whale"), 100_000);

        vm.prank(curator1);
        glt.castCuratorVote(id, true);
        vm.prank(curator2);
        glt.castCuratorVote(id, true);
        // old behaviour: needed 50100 and reverted. Now 200 >= 150 and resolves.
        glt.tallyDispute(id);
        assertEq(uint8(glt.getAttestation(id).status), uint8(GalacticTrust.AttestationStatus.SLASHED));
    }

    // ---------- review expiry / tie-break (bug 8) ----------

    function test_RevertWhen_ExpireBeforeDeadline() public {
        bytes32 id = _submit();
        vm.prank(challenger);
        glt.challengeAttestation(id, "a");
        _skipWindow();
        vm.prank(curator1);
        glt.castCuratorVote(id, true);
        vm.prank(curator2);
        glt.castCuratorVote(id, false);

        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.ReviewNotExpirable.selector, id));
        glt.expireReview(id);
    }

    function test_TieNowExpiresAndRejectsByDefault() public {
        bytes32 id = _submit();
        _signTwo(id);
        vm.prank(challenger);
        glt.challengeAttestation(id, "a");
        _resolveSplit(id);

        // the tie is a hard stop while the window is open...
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.CuratorsSplit.selector, id, 100, 100));
        glt.tallyDispute(id);

        // ...but no longer forever
        vm.warp(block.timestamp + glt.REVIEW_WINDOW() + 1);
        glt.expireReview(id);

        assertEq(
            uint8(glt.getAttestation(id).status),
            uint8(GalacticTrust.AttestationStatus.PENDING),
            "expiry defaults to reject, never a slash"
        );
        assertEq(glt.attesterBond(attester1), BOND, "no penalty for curator inaction");
        assertEq(glt.challengeBond(challenger), 0, "challenger bond forfeited");
        glt.finalizeAttestation(id);
        _assertSolvent();
    }

    function test_UnreachedQuorumExpiresAndRejects() public {
        bytes32 id = _submit();
        _signTwo(id);
        vm.prank(challenger);
        glt.challengeAttestation(id, "a");
        _skipWindow();
        vm.prank(curator1);
        glt.castCuratorVote(id, true);

        vm.warp(block.timestamp + glt.REVIEW_WINDOW() + 1);
        glt.expireReview(id);
        assertEq(uint8(glt.getAttestation(id).status), uint8(GalacticTrust.AttestationStatus.PENDING));
        glt.finalizeAttestation(id);
        _assertSolvent();
    }

    /// Expiry must not launder a positive REFUTED finding. Silence is not acquittal.
    function test_ExpiryDoesNotLaunderRefutedEvidence() public {
        _setVerdict(EvidenceVerdict.REFUTED);
        bytes32 id = _submit();
        _signTwo(id);
        vm.prank(challenger);
        glt.challengeAttestation(id, "a");
        _skipWindow();
        vm.warp(block.timestamp + glt.REVIEW_WINDOW() + 1);

        glt.expireReview(id);
        assertEq(
            uint8(glt.getAttestation(id).status),
            uint8(GalacticTrust.AttestationStatus.SLASHED),
            "a refuted proof is still punished when the panel stays silent"
        );
        assertEq(glt.attesterBond(attester1), 0, "signers still slashed");
        _assertSolvent();
    }

    function test_RevertWhen_ExpireAlreadyResolved() public {
        bytes32 id = _submit();
        vm.prank(challenger);
        glt.challengeAttestation(id, "a");
        _skipWindow();
        _resolveUp(id);

        vm.warp(block.timestamp + glt.REVIEW_WINDOW() + 1);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.NotPendingOrDisputed.selector, id));
        glt.expireReview(id);
    }

    function test_ExpiryUnlocksChallengeBondAfterSettlement() public {
        bytes32 id = _submit();
        vm.prank(challenger);
        glt.challengeAttestation(id, "a");
        _skipWindow();
        vm.warp(block.timestamp + glt.REVIEW_WINDOW() + 1);
        glt.expireReview(id);
        assertEq(glt.lockedChallengeBond(challenger), 0, "lock released on expiry");
        _assertSolvent();
    }

    // ---------- commit-reveal gating ----------

    function test_RevertWhen_RevealDuringWindow() public {
        bytes32 id = _submit();
        vm.prank(curator1);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.ChallengeWindowOpen.selector, id));
        glt.revealSecret(id, SECRET);
    }

    function test_RevertWhen_UnauthorizedReveal() public {
        bytes32 id = _submit();
        _skipWindow();
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.NotAuthorizedRevealer.selector, id, outsider));
        glt.revealSecret(id, SECRET);
        assertFalse(glt.getAttestation(id).secretRevealed, "nothing recorded");
    }

    function test_ChallengerCanRevealAfterWindow() public {
        bytes32 id = _submit();
        vm.prank(challenger);
        glt.challengeAttestation(id, "a");
        _skipWindow();
        vm.prank(challenger);
        glt.revealSecret(id, SECRET);
        assertTrue(glt.getAttestation(id).secretRevealed, "recorded");
    }

    function test_CuratorCanRevealAfterWindow() public {
        bytes32 id = _submit();
        _skipWindow();
        vm.prank(curator1);
        glt.revealSecret(id, SECRET);
        assertTrue(glt.getAttestation(id).secretRevealed, "recorded");
    }

    /// The old implementation wrote `att.secret` unconditionally, so anyone could clobber the
    /// submitter's secret with garbage and a curator reading storage would see the attacker's
    /// value. A wrong guess must now be inert.
    function test_WrongGuessDoesNotCorruptStoredSecret() public {
        bytes32 id = _submit();
        _skipWindow();
        vm.prank(curator1);
        glt.revealSecret(id, SECRET);
        bytes32 good = glt.getAttestation(id).secret;

        vm.prank(curator2);
        glt.revealSecret(id, keccak256("wrong"));
        assertEq(glt.getAttestation(id).secret, good, "stored secret unchanged by a bad guess");
    }

    function test_RevertWhen_RevealTwice() public {
        bytes32 id = _submit();
        _skipWindow();
        vm.prank(curator1);
        glt.revealSecret(id, SECRET);
        vm.prank(curator2);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.AlreadyRevealed.selector, id));
        glt.revealSecret(id, SECRET);
    }

    function test_CheckSecretIsStatelessAndReadOnly() public {
        bytes32 id = _submit();
        assertTrue(glt.checkSecret(id, SECRET), "correct pre-image validates");
        assertFalse(glt.checkSecret(id, keccak256("nope")), "wrong pre-image fails");
        assertFalse(glt.getAttestation(id).secretRevealed, "view call recorded nothing");
    }

    // ---------- governance ----------

    function test_RevertWhen_QuorumAbove100Percent() public {
        vm.prank(owner);
        vm.expectRevert("quorum > 100%");
        glt.setQuorumBps(10_001);
    }

    function test_OwnershipIsTwoStep() public {
        vm.prank(owner);
        glt.transferOwnership(outsider);
        assertEq(glt.owner(), owner, "ownership moves only after accept");
        vm.prank(outsider);
        glt.acceptOwnership();
        assertEq(glt.owner(), outsider);
    }

    // ---------- escrow integrity ----------
    //
    // Regression cover for four defects the original 47 tests did not catch:
    // the owner could burn live escrow, only one of several challengers was ever paid,
    // a challenger could lift its bond the moment it filed, and the challenge bond
    // defaulted to zero so a fresh deploy allowed free challenging.

    function test_RecoverExcessCannotTouchLiveStake() public {
        bytes32 id = _submit();
        assertEq(glt.excessBalance(), 0, "nothing unbacked while stake is live");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.NothingToRecover.selector, MIN_STAKE, 0));
        glt.recoverExcessStake(MIN_STAKE);
        _assertSolvent();

        vm.warp(block.timestamp + glt.CHALLENGE_WINDOW() + 1);
        vm.prank(attester1);
        glt.signAttestation(id);
        vm.prank(attester2);
        glt.signAttestation(id);

        uint256 before = glt.balanceOf(submitter);
        glt.finalizeAttestation(id);
        assertEq(glt.balanceOf(submitter), before + MIN_STAKE + REWARD, "stake returned, reward minted");
        _assertSolvent();
    }

    function test_RecoverExcessCannotTouchBonds() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(GalacticTrust.NothingToRecover.selector, 1, 0));
        glt.recoverExcessStake(1);
        _assertSolvent();
        assertEq(glt.attesterBond(attester1), BOND, "bond untouched");
        assertEq(glt.challengeBond(challenger), CHALLENGE_BOND, "challenge bond untouched");
    }

    function test_SolvencyHoldsThroughAFullDisputeCycle() public {
        bytes32 id = _submit();
        vm.prank(attester1);
        glt.signAttestation(id);
        vm.prank(challenger);
        glt.challengeAttestation(id, "fabricated");
        _resolveUp(id);

        uint256 before = glt.balanceOf(challenger);
        vm.prank(challenger);
        glt.claimChallengeReward(id);
        assertEq(glt.balanceOf(challenger), before + CHALLENGE_BOND, "paid in full");
        _assertSolvent();
        assertEq(glt.excessBalance(), 0, "no dust or shortfall after settlement");
    }

    function test_EveryChallengerIsPaid() public {
        bytes32 id = _submit();
        vm.prank(challenger);
        glt.challengeAttestation(id, "a");
        vm.prank(outsider);
        glt.challengeAttestation(id, "b");
        _resolveUp(id);

        uint256 c1 = glt.balanceOf(challenger);
        uint256 c2 = glt.balanceOf(outsider);
        vm.prank(challenger);
        glt.claimChallengeReward(id);
        vm.prank(outsider);
        glt.claimChallengeReward(id);

        assertEq(glt.balanceOf(challenger), c1 + CHALLENGE_BOND, "first challenger paid");
        assertEq(glt.balanceOf(outsider), c2 + CHALLENGE_BOND, "second challenger paid too");
        assertEq(glt.payoutPool(id), 0, "pool fully drained");
        _assertSolvent();
    }

    function test_RevertWhen_ClaimBondWhileChallenging() public {
        bytes32 id = _submit();
        vm.startPrank(challenger);
        glt.challengeAttestation(id, "fabricated");
        vm.expectRevert(GalacticTrust.NoBondToWithdraw.selector);
        glt.withdrawChallengeBond();
        vm.stopPrank();

        _resolveUp(id);
        assertEq(glt.challengeBond(challenger), 0, "bond consumed by settlement");
    }

    function test_RevertWhen_UnbackedChallengeBondIsWithdrawable() public {
        bytes32 id = _submit();
        vm.startPrank(challenger);
        glt.challengeAttestation(id, "fabricated");
        vm.expectRevert(GalacticTrust.NoBondToWithdraw.selector);
        glt.withdrawChallengeBond();
        vm.stopPrank();

        // the bond is genuinely gone: a rejected dispute has nothing left to burn
        _resolveDown(id);
        assertEq(glt.challengeBond(challenger), 0);
        _assertSolvent();
    }

    function test_ChallengeBondUnlockedAfterSettlement() public {
        bytes32 id = _submit();
        vm.prank(challenger);
        glt.challengeAttestation(id, "a");
        assertEq(glt.lockedChallengeBond(challenger), CHALLENGE_BOND, "bond committed");
        _resolveUp(id);
        assertEq(glt.lockedChallengeBond(challenger), 0, "lock released after settlement");

        // The bond itself was forfeited into the payout pool, so re-challenging needs a fresh
        // one. The point here is only that the lock is not still holding the old bond.
        vm.prank(submitter);
        glt.transfer(challenger, CHALLENGE_BOND);
        vm.prank(challenger);
        glt.fundChallengeBond(CHALLENGE_BOND);

        bytes32 next = _submitDistinct("b");
        vm.prank(challenger);
        glt.challengeAttestation(next, "another round");
        assertEq(glt.lockedChallengeBond(challenger), CHALLENGE_BOND, "can bond again");
    }

    function test_FreshDeployIsNotFreeToChallenge() public {
        GalacticTrust fresh = new GalacticTrust(owner, MIN_STAKE, address(0), TREASURY, submitter);
        assertGt(fresh.challengeBondAmount(), 0, "challenge bond defaults to non-zero");
        assertGt(fresh.attesterBondAmount(), 0, "attester bond defaults to non-zero");

        fresh.registerAttester(attester1, 100);
        vm.prank(submitter);
        bytes32 id = fresh.submitAttestation(contentHash, SECRET, GalacticTrust.EvidenceTier.R2);

        address nobody = makeAddr("nobody");
        vm.prank(nobody);
        vm.expectRevert(
            abi.encodeWithSelector(GalacticTrust.BondBelowRequired.selector, 0, fresh.challengeBondAmount())
        );
        fresh.challengeAttestation(id, "free grief");
    }

    function test_RevertWhen_ChallengeBondSetToZero() public {
        vm.prank(owner);
        vm.expectRevert(GalacticTrust.ZeroAmount.selector);
        glt.setChallengeBondAmount(0);
    }

    function test_SolvencySurvivesManyConcurrentAttestations() public {
        bytes32 id0 = _submitDistinct("a0");
        bytes32 id1 = _submitDistinct("a1");
        bytes32 id2 = _submitDistinct("a2");
        bytes32 id3 = _submitDistinct("a3");
        assertEq(glt.totalStaked(), MIN_STAKE * 4, "all stakes tracked");
        _assertSolvent();

        // id0 settles cleanly, id1 is slashed, id3's challenge is rejected, id2 stays pending.
        // Every challenge is filed before any warp: the window is absolute, so settling one
        // attestation closes the filing period for everything submitted alongside it.
        vm.prank(challenger);
        glt.challengeAttestation(id1, "fabricated");
        vm.prank(outsider);
        glt.challengeAttestation(id3, "wrong call");

        vm.warp(block.timestamp + glt.CHALLENGE_WINDOW() + 1);
        vm.prank(attester1);
        glt.signAttestation(id0);
        vm.prank(attester2);
        glt.signAttestation(id0);
        glt.finalizeAttestation(id0);

        vm.prank(curator1);
        glt.castCuratorVote(id1, true);
        vm.prank(curator2);
        glt.castCuratorVote(id1, true);
        glt.tallyDispute(id1);

        vm.prank(curator1);
        glt.castCuratorVote(id3, false);
        vm.prank(curator2);
        glt.castCuratorVote(id3, false);
        glt.tallyDispute(id3);

        vm.prank(challenger);
        glt.claimChallengeReward(id1);
        _assertSolvent();
        assertEq(glt.excessBalance(), 0, "book balances across mixed outcomes");
    }
}
