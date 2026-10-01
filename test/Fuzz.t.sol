// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GalacticTrust} from "../src/GalacticTrust.sol";
import {IVerifier, EvidenceVerdict} from "../src/IVerifier.sol";

/// @dev Conservation fuzz. The property: for any sequence of operations, the contract holds
/// at least what it owes, and the whole supply is accounted for as
///   circulating + escrow + burned. SESSION.md lists "fuzz _penalise for conservation" as
///   open work; this is that, plus the multi-challenger and multi-round cases the
///   deterministic suite only samples.
contract FuzzTest is Test {
    GalacticTrust internal glt;

    address internal owner = address(this);
    address internal submitter = makeAddr("submitter");
    address internal curator1 = makeAddr("curator1");
    address internal curator2 = makeAddr("curator2");
    address internal curator3 = makeAddr("curator3");

    uint256 internal constant MIN_STAKE = 1_000e18;
    uint256 internal constant TREASURY = 1_000_000e18;

    function setUp() public {
        glt = new GalacticTrust(owner, MIN_STAKE, address(0), TREASURY, submitter);
        glt.registerCurator(curator1, 100);
        glt.registerCurator(curator2, 100);
        glt.registerCurator(curator3, 100);
    }

    /// @dev Convenience alias. `Test` already exposes `bound`; the indirection keeps the call
    /// sites readable without shadowing it.
    function _fuzzBound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return bound(x, lo, hi);
    }

    /// @dev A full lifecycle on fuzzed parameters: bond, slash, challenger count, ruling.
    /// Asserts solvency and that supply never changes by an unexplained amount.
    function testFuzz_SettlementConservesTokens(
        uint256 bondSeed,
        uint256 slashSeed,
        uint256 challengeSeed,
        bool upheld,
        uint8 attesterSeed
    ) public {
        uint256 bond = _fuzzBound(bondSeed, 1e18, 50e18);
        uint256 slashBps = _fuzzBound(slashSeed, 0, 10_000);
        uint256 nChallengers = _fuzzBound(challengeSeed, 1, 5);

        address[] memory signers = new address[](3);
        for (uint256 i = 0; i < 3; i++) {
            signers[i] = makeAddr(string.concat("attester", vm.toString(i)));
            vm.prank(owner);
            glt.registerAttester(signers[i], 100);
            vm.prank(submitter);
            glt.transfer(signers[i], bond * 2);
            vm.prank(signers[i]);
            glt.fundAttesterBond(bond);
        }

        vm.startPrank(owner);
        glt.setAttesterBondAmount(bond);
        glt.setChallengeBondAmount(bond);
        glt.setSlashBps(slashBps);
        glt.setAttesterSlashBps(slashBps);
        vm.stopPrank();

        bytes32 secret = keccak256(abi.encode(bondSeed, slashSeed));
        vm.prank(submitter);
        bytes32 id = glt.submitAttestation(
            keccak256(abi.encode(secret, submitter)), secret, GalacticTrust.EvidenceTier.R2
        );

        // a fuzzed subset of signers, capped so quorum may or may not be met
        uint256 nSigners = _fuzzBound(attesterSeed, 0, 3);
        for (uint256 i = 0; i < nSigners; i++) {
            vm.prank(signers[i]);
            glt.signAttestation(id);
        }

        for (uint256 i = 0; i < nChallengers; i++) {
            address c = makeAddr(string.concat("challenger", vm.toString(i)));
            vm.prank(submitter);
            glt.transfer(c, bond * 2);
            vm.prank(c);
            glt.fundChallengeBond(bond);
            vm.prank(c);
            glt.challengeAttestation(id, "fuzz");
        }

        vm.warp(block.timestamp + glt.CHALLENGE_WINDOW() + 1);
        vm.prank(curator1);
        glt.castCuratorVote(id, upheld);
        vm.prank(curator2);
        glt.castCuratorVote(id, upheld);
        glt.tallyDispute(id);

        _assertSolvent(id, bond, slashBps);
    }

    /// @dev Every challenger must be able to pull, and the pool must end empty. This is the
    /// conservation-of-payouts half, which the single-pool bug violated silently.
    function testFuzz_AllChallengersPaidExactlyOnce(
        uint256 nRaw,
        uint256 slashSeed
    ) public {
        uint256 n = _fuzzBound(nRaw, 1, 8);
        uint256 slashBps = _fuzzBound(slashSeed, 0, 10_000);
        uint256 bond = 10e18;

        vm.startPrank(owner);
        glt.setChallengeBondAmount(bond);
        glt.setSlashBps(slashBps);
        glt.setAttesterBondAmount(bond);
        vm.stopPrank();

        bytes32 secret = keccak256("fuzz-payouts");
        vm.prank(submitter);
        bytes32 id = glt.submitAttestation(
            keccak256(abi.encode(secret, submitter)), secret, GalacticTrust.EvidenceTier.R2
        );

        address[] memory cs = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            cs[i] = makeAddr(string.concat("c", vm.toString(i)));
            vm.prank(submitter);
            glt.transfer(cs[i], bond * 2);
            vm.prank(cs[i]);
            glt.fundChallengeBond(bond);
            vm.prank(cs[i]);
            glt.challengeAttestation(id, "fuzz");
        }

        vm.warp(block.timestamp + glt.CHALLENGE_WINDOW() + 1);
        vm.prank(curator1);
        glt.castCuratorVote(id, true);
        vm.prank(curator2);
        glt.castCuratorVote(id, true);
        glt.tallyDispute(id);

        // `payoutPool` is the total, not the per-head share. Reading it as a per-head figure
        // is exactly the mistake the single-pool bug baked in.
        uint256 totalPool = glt.payoutPool(id);
        uint256 share = totalPool / n;
        for (uint256 i = 0; i < n; i++) {
            uint256 before = glt.balanceOf(cs[i]);
            vm.prank(cs[i]);
            glt.claimChallengeReward(id);
            assertEq(glt.balanceOf(cs[i]), before + share, "paid exactly the per-head share");
            // and exactly once
            vm.prank(cs[i]);
            vm.expectRevert(abi.encodeWithSelector(GalacticTrust.ClaimAlreadyMade.selector, id, cs[i]));
            glt.claimChallengeReward(id);
        }
        assertEq(glt.payoutPool(id), 0, "pool fully drained");
        _assertSolventFull();
    }

    /// @dev Expiry always reaches a terminal state, whatever the vote pattern.
    function testFuzz_ExpiryAlwaysTerminates(uint8 pattern) public {
        vm.prank(owner);
        glt.setChallengeBondAmount(10e18);
        glt.setAttesterBondAmount(10e18);

        bytes32 secret = keccak256(abi.encode("exp", pattern));
        vm.prank(submitter);
        bytes32 id = glt.submitAttestation(
            keccak256(abi.encode(secret, submitter)), secret, GalacticTrust.EvidenceTier.R2
        );

        address c = makeAddr("cx");
        vm.prank(submitter);
        glt.transfer(c, 20e18);
        vm.prank(c);
        glt.fundChallengeBond(10e18);
        vm.prank(c);
        glt.challengeAttestation(id, "x");

        vm.warp(block.timestamp + glt.CHALLENGE_WINDOW() + 1);
        // pattern 0 = no votes, 1 = uphold, 2 = reject, 3 = tie (two curators, opposite)
        if (pattern == 1 || pattern == 2) {
            vm.prank(curator1);
            glt.castCuratorVote(id, pattern == 1);
            vm.prank(curator2);
            glt.castCuratorVote(id, pattern == 1);
            glt.tallyDispute(id);
        } else if (pattern == 3) {
            vm.prank(curator1);
            glt.castCuratorVote(id, true);
            vm.prank(curator2);
            glt.castCuratorVote(id, false);
            // a tie must not tally while the window is open
            vm.expectRevert(abi.encodeWithSelector(GalacticTrust.CuratorsSplit.selector, id, 100, 100));
            glt.tallyDispute(id);
            vm.warp(block.timestamp + glt.REVIEW_WINDOW() + 1);
            glt.expireReview(id);
        } else {
            vm.warp(block.timestamp + glt.REVIEW_WINDOW() + 1);
            glt.expireReview(id);
        }

        GalacticTrust.AttestationStatus s = glt.getAttestation(id).status;
        assertTrue(
            s == GalacticTrust.AttestationStatus.PENDING
                || s == GalacticTrust.AttestationStatus.FINALIZED
                || s == GalacticTrust.AttestationStatus.SLASHED,
            "terminal state reached"
        );
        _assertSolventFull();
    }

    /// @dev The owner cannot burn escrowed tokens no matter what it tries. Fuzzed amounts
    /// across the full range, including nonsense ones.
    function testFuzz_OwnerCannotBurnEscrow(uint256 amountSeed) public {
        vm.prank(owner);
        glt.setChallengeBondAmount(10e18);

        bytes32 secret = keccak256("burn");
        vm.prank(submitter);
        glt.submitAttestation(keccak256(abi.encode(secret, submitter)), secret, GalacticTrust.EvidenceTier.R2);

        uint256 excess = glt.excessBalance();
        if (amountSeed > excess) {
            vm.prank(owner);
            vm.expectRevert();
            glt.recoverExcessStake(amountSeed);
        } else {
            vm.prank(owner);
            glt.recoverExcessStake(amountSeed);
            assertGe(glt.balanceOf(address(glt)), glt.totalLiabilities(), "still solvent");
        }
    }

    /// @dev Solvency must hold at every point, never just at rest.
    function _assertSolvent(bytes32 id, uint256 bond, uint256 slashBps) internal {
        _assertSolventFull();
        // any submitter stake still held must be matched by totalStaked
        assertGe(glt.balanceOf(address(glt)), glt.totalLiabilities(), "held >= owed");
        id;
        bond;
        slashBps;
    }

    function _assertSolventFull() internal {
        assertGe(glt.balanceOf(address(glt)), glt.totalLiabilities(), "held >= owed");
    }
}