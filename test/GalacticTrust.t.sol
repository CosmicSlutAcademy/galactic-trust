// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GalacticTrust} from "../src/GalacticTrust.sol";
import {IVerifier} from "../src/IVerifier.sol";

contract MockVerifier is IVerifier {
    bool public pass;

    constructor(bool _pass) {
        pass = _pass;
    }

    function setPass(bool _pass) external {
        pass = _pass;
    }

    function verifyEvidence(bytes32, uint8) external view returns (bool) {
        return pass;
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

    function setUp() public {
        glt = new GalacticTrust(owner, MIN_STAKE, address(0), TREASURY, submitter);
        glt.registerAttester(attester1, 100);
        glt.registerAttester(attester2, 100);
        glt.registerAttester(attester3, 100);
        glt.registerCurator(curator1, 100);
        glt.registerCurator(curator2, 100);
        glt.registerCurator(curator3, 100);
        contentHash = keccak256(abi.encode(SECRET, submitter));

        vm.startPrank(owner);
        glt.setRewardAmount(REWARD);
        glt.setAttesterBondAmount(BOND);
        glt.setChallengeBondAmount(CHALLENGE_BOND);
        vm.stopPrank();

        _fund(attester1);
        _fund(attester2);
        _fund(attester3);
        _fundChallenger(challenger);
        _fundChallenger(outsider);
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

    function _skipWindow() internal {
        vm.warp(block.timestamp + glt.CHALLENGE_WINDOW() + 1);
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
        assertEq(glt.balanceOf(address(glt)), BOND * 3 + CHALLENGE_BOND * 2 + MIN_STAKE, "bonds + challenge bonds + stake");
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
        vm.expectRevert(
            abi.encodeWithSelector(GalacticTrust.QuorumNotReached.selector, id, 100, 150)
        );
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
        assertEq(glt.balanceOf(address(glt)), BOND * 3 + CHALLENGE_BOND * 2, "attester + challenge bonds remain");
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
        assertEq(
            glt.totalSupply(),
            supplyBefore - MIN_STAKE - (BOND * 2),
            "submitter stake + both signer bonds burned"
        );
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
        vm.expectRevert(
            abi.encodeWithSelector(GalacticTrust.CuratorQuorumNotReached.selector, id, 100, 150)
        );
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
        vm.expectRevert(
            abi.encodeWithSelector(GalacticTrust.BondBelowRequired.selector, 0, CHALLENGE_BOND)
        );
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
        vm.expectRevert(
            abi.encodeWithSelector(GalacticTrust.ClaimAlreadyMade.selector, id, challenger)
        );
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
        vm.expectRevert(
            abi.encodeWithSelector(GalacticTrust.NothingToClaim.selector, id, challenger)
        );
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

    // ---------- verifier hook ----------

    function test_VerifierGateFailsAndPasses() public {
        MockVerifier mockV = new MockVerifier(false);
        vm.prank(owner);
        glt.setVerifier(address(mockV));
        bytes32 id = _submit();
        assertFalse(glt.passesVerifier(id));
        mockV.setPass(true);
        assertTrue(glt.passesVerifier(id));
    }

    function test_PassesVerifierTrueWhenUnset() public {
        bytes32 id = _submit();
        assertTrue(glt.passesVerifier(id));
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
}
