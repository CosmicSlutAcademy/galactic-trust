// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {IVerifier, EvidenceVerdict} from "./IVerifier.sol";

contract GalacticTrust is ERC20, ERC20Permit, ERC20Votes, Ownable2Step, ReentrancyGuard {
    enum EvidenceTier {
        UNVERIFIED,
        R0,
        R1,
        R2,
        R3,
        R4,
        R5
    }

    enum AttestationStatus {
        NONE,
        PENDING,
        FINALIZED,
        SLASHED
    }

    struct Attester {
        address account;
        uint128 weight;
        bool active;
    }

    struct Attestation {
        bytes32 id;
        address submitter;
        bytes32 contentHash;
        bytes32 secret;
        EvidenceTier tier;
        AttestationStatus status;
        uint64 submittedAt;
        uint64 challengeDeadline;
        uint128 attestationWeight;
        uint128 quorumWeight;
        uint256 stake;

        /// @dev Snapshotted at submission alongside `quorumWeight`. Reading curator quorum
        /// live at tally time let the owner appoint a whale curator mid-dispute and push the
        /// bar above reachable weight, freezing the dispute with funds locked.
        uint128 curatorQuorumWeight;
        /// @dev When an unresolved verdict must be forced to a ruling. After this, a dispute
        /// that has not reached quorum or is tied can be expired instead of stalling forever.
        uint64 reviewDeadline;
        /// @dev Set once the pre-image has been disclosed and matched. Gates a second reveal.
        bool secretRevealed;
        /// @dev Set when a curator panel rejects a machine referral (REFUTED/UNRESOLVED with
        /// no challenger). Records that the humans deliberately overrode the verdict, which is
        /// the only way such an attestation becomes finalizable. Without this a rejected
        /// referral would deadlock: it cannot finalize (verdict) and cannot be disputed again.
        bool panelOverride;
    }

    error NotAttester(address account);
    error AttesterInactive(address account);
    error AlreadyAttested(bytes32 id, address account);
    error AttestationNotPending(bytes32 id);
    error AttestationNotFinalized(bytes32 id);
    error ChallengeWindowClosed(bytes32 id);
    error ChallengeWindowOpen(bytes32 id);
    error QuorumReached(bytes32 id);
    error QuorumNotReached(bytes32 id, uint256 have, uint256 need);
    error AlreadyChallenged(bytes32 id, address challenger);
    error AttestationUnderChallenge(bytes32 id);
    error NoChallengesToResolve(bytes32 id);
    error InsufficientStake(uint256 have, uint256 need);
    error InvalidSecret();
    error TierOutOfRange();
    error NotPendingOrDisputed(bytes32 id);
    error ZeroAddress();
    error BondBelowRequired(uint256 have, uint256 need);
    error AttesterStillActive(address account);
    error NoBondToWithdraw();
    error NotCurator(address account);
    error CuratorInactive(address account);
    error AlreadyVoted(bytes32 id, address curator);
    error CuratorVoteTooEarly(bytes32 id);
    error CuratorQuorumNotReached(bytes32 id, uint256 have, uint256 need);
    error CuratorsSplit(bytes32 id, uint256 upholdWeight, uint256 rejectWeight);
    error TooManySigners(bytes32 id);
    error TooManyChallengers(bytes32 id);
    error NothingToRecover(uint256 requested, uint256 excess);
    error ClaimAlreadyMade(bytes32 id, address account);
    error NothingToClaim(bytes32 id, address account);
    error NotAChallenger(bytes32 id, address account);
    error ZeroAmount();
    error EvidenceNotFinalizable(bytes32 id, uint8 verdict);
    error ReviewNotExpirable(bytes32 id);
    error ReviewAlreadyResolved(bytes32 id);
    error NotAuthorizedRevealer(bytes32 id, address account);
    error AlreadyRevealed(bytes32 id);
    error ReviewNotOpen(bytes32 id);
    error VerifierReverted(bytes32 id);
    event AttesterRegistered(address indexed account, uint128 weight);
    event AttesterWeightUpdated(address indexed account, uint128 weight);
    event AttesterDeactivated(address indexed account);
    event AttestationSubmitted(
        bytes32 indexed id,
        address indexed submitter,
        bytes32 contentHash,
        EvidenceTier tier,
        uint256 stake
    );
    event AttestationSigned(bytes32 indexed id, address indexed attester, uint128 weight);
    event AttestationFinalized(bytes32 indexed id, address indexed submitter, uint256 reward);
    event AttestationChallenged(bytes32 indexed id, address indexed challenger, bytes32 reason);
    event DisputeResolved(bytes32 indexed id, bool upheld);
    event AttestationSlashed(bytes32 indexed id, address indexed submitter, uint256 amount);
    event AttesterSlashed(bytes32 indexed id, address indexed attester, uint256 amount);
    event ChallengerRewarded(bytes32 indexed id, address indexed challenger, uint256 amount);
    event AttesterBondFunded(address indexed account, uint256 amount);
    event AttesterBondWithdrawn(address indexed account, uint256 amount);
    event CuratorRegistered(address indexed account, uint128 weight);
    event CuratorDeactivated(address indexed account);
    event CuratorVoted(bytes32 indexed id, address indexed curator, bool uphold, uint128 weight);
    event Disputed(bytes32 indexed id, uint256 upholdWeight, uint256 rejectWeight);
    event ChallengeRewardClaimed(bytes32 indexed id, address indexed account, uint256 amount);
    event PoolSeeded(bytes32 indexed id, uint256 each, uint256 challengers);
    event ReviewExpired(bytes32 indexed id, uint256 upholdWeight, uint256 rejectWeight);
    event ChallengerBondForfeited(bytes32 indexed id, address indexed challenger, uint256 amount);
    event SecretRevealed(bytes32 indexed id, bytes32 contentHash, bool valid);
    event VerifierSet(address indexed verifier);

    uint128 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant CHALLENGE_WINDOW = 2 days;

    /// @dev How long a curator panel has to rule before the dispute can be expired. An
    /// unreached quorum or a tie used to lock stake and bonds with no exit at all.
    uint256 public constant REVIEW_WINDOW = 7 days;

    /// @dev Hard caps so settlement cost is bounded regardless of committee size.
    uint256 public constant MAX_SIGNERS = 50;
    uint256 public constant MAX_CHALLENGERS = 50;

    IVerifier public verifier;
    uint256 public quorumBps = 5_000;
    uint256 public minStake;
    uint256 public totalAttesterWeight;
    uint256 public rewardAmount = 100e18;
    uint256 public slashBps = 10_000;
    uint256 public attesterBondAmount = 100e18;
    uint256 public attesterSlashBps = 10_000;

    mapping(address => Attester) private _attesters;
    mapping(bytes32 => Attestation) private _attestations;
    mapping(bytes32 => mapping(address => bool)) public hasSigned;
    mapping(bytes32 => mapping(address => bool)) public hasChallenged;
    mapping(bytes32 => address[]) public challengers;
    mapping(bytes32 => address[]) public signers;
    mapping(address => uint256) public attesterBond;
    mapping(bytes32 => bool) public disputeUpheld;
    mapping(address => Attester) private _curators;
    mapping(bytes32 => mapping(address => bool)) public curatorVote;
    mapping(bytes32 => uint128) public upholdWeight;
    mapping(bytes32 => uint128) public rejectWeight;
    mapping(bytes32 => mapping(address => bool)) public hasClaimed;
    mapping(bytes32 => mapping(address => bool)) public wasChallenger;

    /// @dev Challenge bond committed to a specific open challenge. The aggregate in
    /// `lockedChallengeBond` gates withdrawal; this per-attestation figure makes the
    /// release exact even if `challengeBondAmount` is re-set while a dispute is in flight.
    mapping(bytes32 => mapping(address => uint256)) public challengeLock;
    mapping(address => uint256) public lockedChallengeBond;

    /// @dev Each challenger's settled entitlement, assigned once at tally time. A single
    /// shared `payoutPool` figure cannot express N independent claims: the first claimer
    /// zeroes it and the rest revert, stranding the remainder.
    mapping(bytes32 => mapping(address => uint256)) public payoutShare;
    uint256 public totalCuratorWeight;
    uint256 public challengeBondAmount = 100e18;
    mapping(address => uint256) public challengeBond;
    mapping(bytes32 => uint256) public payoutPool;

    /// @dev Tokens the contract owes and may never burn. Kept as a running total so an
    /// accounting mistake surfaces as a revert in the tests rather than as insolvency in
    /// production. `balanceOf(address(this))` is the sum of every liability below.
    uint256 public totalStaked;
    uint256 public totalPayoutEscrow;
    uint256 public outstandingAttesterBond;
    uint256 public outstandingChallengeBond;

    modifier onlyAttester() {
        Attester storage a = _attesters[msg.sender];
        if (a.account == address(0)) revert NotAttester(msg.sender);
        if (!a.active) revert AttesterInactive(msg.sender);
        _;
    }

    modifier onlyCurator() {
        Attester storage c = _curators[msg.sender];
        if (c.account == address(0)) revert NotCurator(msg.sender);
        if (!c.active) revert CuratorInactive(msg.sender);
        _;
    }

    constructor(address initialOwner, uint256 _minStake, address _verifier, uint256 initialSupply, address treasury)
        ERC20("Galactic Trust", "GLT")
        ERC20Permit("Galactic Trust")
        Ownable(initialOwner)
    {
        if (initialOwner == address(0)) revert ZeroAddress();
        if (treasury == address(0)) revert ZeroAddress();
        minStake = _minStake;
        if (_verifier != address(0)) verifier = IVerifier(_verifier);
        if (initialSupply > 0) _mint(treasury, initialSupply);
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }

    function setVerifier(address _verifier) external onlyOwner {
        verifier = IVerifier(_verifier);
        emit VerifierSet(_verifier);
    }

    function setQuorumBps(uint256 bps) external onlyOwner {
        require(bps <= BPS_DENOMINATOR, "quorum > 100%");
        quorumBps = bps;
    }

    function setMinStake(uint256 _minStake) external onlyOwner {
        minStake = _minStake;
    }

    function setRewardAmount(uint256 _reward) external onlyOwner {
        rewardAmount = _reward;
    }

    function setSlashBps(uint256 bps) external onlyOwner {
        require(bps <= BPS_DENOMINATOR, "slash > 100%");
        slashBps = bps;
    }

    function setAttesterBondAmount(uint256 amount) external onlyOwner {
        attesterBondAmount = amount;
    }

    function setAttesterSlashBps(uint256 bps) external onlyOwner {
        require(bps <= BPS_DENOMINATOR, "slash > 100%");
        attesterSlashBps = bps;
    }

    /// @notice Locks GLT as an attester bond. Required before an attester may sign anything.
    function fundAttesterBond(uint256 amount) external nonReentrant onlyAttester {
        uint256 bal = balanceOf(msg.sender);
        if (bal < amount) revert InsufficientStake(bal, amount);
        _update(msg.sender, address(this), amount);
        attesterBond[msg.sender] += amount;
        outstandingAttesterBond += amount;
        emit AttesterBondFunded(msg.sender, amount);
    }

    /// @notice Withdraws the bond. Only possible once deactivated, so a validator cannot
    /// bond, certify, and immediately withdraw before a dispute resolves.
    function withdrawAttesterBond() external nonReentrant {
        if (_attesters[msg.sender].active) revert AttesterStillActive(msg.sender);
        uint256 amount = attesterBond[msg.sender];
        if (amount == 0) revert NoBondToWithdraw();
        attesterBond[msg.sender] = 0;
        outstandingAttesterBond -= amount;
        _update(address(this), msg.sender, amount);
        emit AttesterBondWithdrawn(msg.sender, amount);
    }

    // ---------- curators ----------

    function registerCurator(address account, uint128 weight) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        Attester storage c = _curators[account];
        if (c.account == address(0)) {
            c.account = account;
            c.active = true;
            c.weight = weight;
            totalCuratorWeight += weight;
        } else {
            totalCuratorWeight = totalCuratorWeight - c.weight + weight;
            c.weight = weight;
            c.active = true;
        }
        emit CuratorRegistered(account, weight);
    }

    function deactivateCurator(address account) external onlyOwner {
        Attester storage c = _curators[account];
        totalCuratorWeight -= c.weight;
        c.active = false;
        c.weight = 0;
        emit CuratorDeactivated(account);
    }

    function curator(address account) external view returns (Attester memory) {
        return _curators[account];
    }

    function curatorQuorumWeight() public view returns (uint256) {
        return (totalCuratorWeight * quorumBps) / BPS_DENOMINATOR;
    }

    /// @notice Deposits GLT that is forfeited if a challenge turns out to be frivolous.
    function fundChallengeBond(uint256 amount) external nonReentrant {
        uint256 bal = balanceOf(msg.sender);
        if (bal < amount) revert InsufficientStake(bal, amount);
        _update(msg.sender, address(this), amount);
        challengeBond[msg.sender] += amount;
        outstandingChallengeBond += amount;
    }

    /// @dev Rejects zero. A zero bond makes challenging free, which reinstates exactly the
    /// griefing vector the bond exists to close, so it cannot be set back to free.
    function setChallengeBondAmount(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        challengeBondAmount = amount;
    }

    /// @notice Withdraws only the bond that is not backing an open challenge. A challenger that
    /// could lift its bond the instant it filed could never lose it, so the anti-frivolity
    /// guarantee would not exist.
    function withdrawChallengeBond() external nonReentrant {
        uint256 amount = challengeBond[msg.sender] - lockedChallengeBond[msg.sender];
        if (amount == 0) revert NoBondToWithdraw();
        challengeBond[msg.sender] -= amount;
        outstandingChallengeBond -= amount;
        _update(address(this), msg.sender, amount);
    }

    function registerAttester(address account, uint128 weight) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        Attester storage a = _attesters[account];
        if (a.account == address(0)) {
            a.account = account;
            a.active = true;
            a.weight = weight;
            totalAttesterWeight += weight;
        } else {
            totalAttesterWeight = totalAttesterWeight - a.weight + weight;
            a.weight = weight;
            a.active = true;
        }
        emit AttesterRegistered(account, weight);
    }

    function deactivateAttester(address account) external onlyOwner {
        Attester storage a = _attesters[account];
        totalAttesterWeight -= a.weight;
        a.active = false;
        a.weight = 0;
        emit AttesterDeactivated(account);
    }

    function attester(address account) external view returns (Attester memory) {
        return _attesters[account];
    }

    function attestation(bytes32 id) external view returns (Attestation memory) {
        return _attestations[id];
    }

    function getAttestation(bytes32 id) external view returns (Attestation memory) {
        return _attestations[id];
    }

    function requiredQuorumWeight() public view returns (uint256) {
        return (totalAttesterWeight * quorumBps) / BPS_DENOMINATOR;
    }

    function challengeCount(bytes32 id) external view returns (uint256) {
        return challengers[id].length;
    }

    function signerWeight(bytes32 id) external view returns (uint256) {
        return _attestations[id].attestationWeight;
    }

    /// @notice Locks stake and opens a challenge window. No tokens are minted here.
    function submitAttestation(bytes32 contentHash, bytes32 secret, EvidenceTier tier)
        external
        nonReentrant
        returns (bytes32 id)
    {
        if (tier == EvidenceTier.UNVERIFIED) revert TierOutOfRange();
        if (minStake > 0) {
            uint256 bal = balanceOf(msg.sender);
            if (bal < minStake) revert InsufficientStake(bal, minStake);
            _update(msg.sender, address(this), minStake);
            totalStaked += minStake;
        }
        id = keccak256(abi.encode(msg.sender, contentHash, block.timestamp, secret));
        Attestation storage att = _attestations[id];
        att.id = id;
        att.submitter = msg.sender;
        att.contentHash = contentHash;
        att.secret = secret;
        att.tier = tier;
        att.status = AttestationStatus.PENDING;
        att.submittedAt = uint64(block.timestamp);
        att.challengeDeadline = uint64(block.timestamp + CHALLENGE_WINDOW);
        att.quorumWeight = uint128(requiredQuorumWeight());
        att.curatorQuorumWeight = uint128(curatorQuorumWeight());
        att.reviewDeadline = uint64(block.timestamp + CHALLENGE_WINDOW + REVIEW_WINDOW);
        att.stake = minStake;
        emit AttestationSubmitted(id, msg.sender, contentHash, tier, minStake);
    }

    /// @notice Attesters co-sign. Weight is snapshotted into the attestation.
    function signAttestation(bytes32 id) external onlyAttester {
        Attestation storage att = _attestations[id];
        if (att.status != AttestationStatus.PENDING) revert AttestationNotPending(id);
        if (hasSigned[id][msg.sender]) revert AlreadyAttested(id, msg.sender);
        uint256 bond = attesterBond[msg.sender];
        if (bond < attesterBondAmount)
            revert BondBelowRequired(bond, attesterBondAmount);
        Attester storage a = _attesters[msg.sender];
        if (signers[id].length >= MAX_SIGNERS) revert TooManySigners(id);
        hasSigned[id][msg.sender] = true;
        signers[id].push(msg.sender);
        att.attestationWeight += a.weight;
        emit AttestationSigned(id, msg.sender, a.weight);
    }

    /// @notice Mints the reward. Requires a CONFIRMED verdict, quorum, an expired challenge
    /// window, and zero challenges. A REFUTED or UNRESOLVED verdict cannot be finalized here:
    /// both must clear a curator panel instead, which is the failsafe that stops a broken
    /// verifier from either freezing the protocol or silently minting.
    function finalizeAttestation(bytes32 id) external nonReentrant {
        Attestation storage att = _attestations[id];
        if (att.status == AttestationStatus.FINALIZED) revert QuorumReached(id);
        if (att.status != AttestationStatus.PENDING) revert AttestationNotPending(id);
        if (block.timestamp <= att.challengeDeadline) revert ChallengeWindowOpen(id);
        if (challengers[id].length > 0) revert AttestationUnderChallenge(id);
        EvidenceVerdict verdict = _verdict(att);
        // A panel may deliberately override a REFUTED/UNRESOLVED referral. A CONFIRMED verdict
        // with a rejected referral is already covered by `panelOverride` being false.
        if (verdict != EvidenceVerdict.CONFIRMED && !att.panelOverride)
            revert EvidenceNotFinalizable(id, uint8(verdict));
        if (att.attestationWeight < att.quorumWeight)
            revert QuorumNotReached(id, att.attestationWeight, att.quorumWeight);
        att.status = AttestationStatus.FINALIZED;
        if (att.stake > 0) {
            totalStaked -= att.stake;
            _update(address(this), att.submitter, att.stake);
        }
        _mint(att.submitter, rewardAmount);
        emit AttestationFinalized(id, att.submitter, rewardAmount);
    }

    /// @dev Reads the verifier defensively. No verifier means CONFIRMED, so the honest
    /// "no opinion available" case does not block an otherwise valid attestation. A reverting
    /// verifier is treated as UNRESOLVED rather than propagating, because a broken proof system
    /// must not be able to halt finalization for every attestation at once.
    function _verdict(Attestation storage att) internal view returns (EvidenceVerdict) {
        address v = address(verifier);
        if (v == address(0)) return EvidenceVerdict.CONFIRMED;
        try IVerifier(v).verifyEvidence(att.contentHash, uint8(att.tier)) returns (
            EvidenceVerdict verdict
        ) {
            return verdict;
        } catch {
            return EvidenceVerdict.UNRESOLVED;
        }
    }

    /// @notice Red-team flag. Challenges accumulate; a single challenger cannot freeze an
    /// attestation, so escalation is a quorum event rather than one party's decision.
    function challengeAttestation(bytes32 id, bytes32 reason) external {
        Attestation storage att = _attestations[id];
        if (att.status != AttestationStatus.PENDING) revert AttestationNotPending(id);
        if (block.timestamp > att.challengeDeadline) revert ChallengeWindowClosed(id);
        if (hasChallenged[id][msg.sender]) revert AlreadyChallenged(id, msg.sender);
        if (challengers[id].length >= MAX_CHALLENGERS) revert TooManyChallengers(id);
        uint256 bond = challengeBond[msg.sender] - lockedChallengeBond[msg.sender];
        if (bond < challengeBondAmount)
            revert BondBelowRequired(bond, challengeBondAmount);
        challengeLock[id][msg.sender] = challengeBondAmount;
        lockedChallengeBond[msg.sender] += challengeBondAmount;
        hasChallenged[id][msg.sender] = true;
        wasChallenger[id][msg.sender] = true;
        challengers[id].push(msg.sender);
        emit AttestationChallenged(id, msg.sender, reason);
    }

    /// @notice Records a curator's ruling. Replaces a single owner key with a weighted panel:
    /// an honest attestation can no longer be slashed by one compromised wallet.
    function castCuratorVote(bytes32 id, bool uphold) external onlyCurator {
        Attestation storage att = _attestations[id];
        if (att.status != AttestationStatus.PENDING) revert NotPendingOrDisputed(id);
        if (block.timestamp <= att.challengeDeadline) revert CuratorVoteTooEarly(id);
        // A referral needs no challenger: a REFUTED or UNRESOLVED verdict is reviewable on
        // its own. Rejecting that case here would leave the tri-state gate with no exit.
        if (challengers[id].length == 0 && _verdict(att) == EvidenceVerdict.CONFIRMED)
            revert NoChallengesToResolve(id);
        if (curatorVote[id][msg.sender]) revert AlreadyVoted(id, msg.sender);
        Attester storage c = _curators[msg.sender];
        curatorVote[id][msg.sender] = true;
        if (uphold) {
            upholdWeight[id] += c.weight;
        } else {
            rejectWeight[id] += c.weight;
        }
        emit CuratorVoted(id, msg.sender, uphold, c.weight);
    }

    /// @notice Applies the ruling once curator quorum is reached. Weight must not be tied,
    /// otherwise the dispute stalls and funds sit locked indefinitely.
    function tallyDispute(bytes32 id) external nonReentrant {
        Attestation storage att = _attestations[id];
        if (att.status != AttestationStatus.PENDING) revert NotPendingOrDisputed(id);
        if (block.timestamp <= att.challengeDeadline) revert CuratorVoteTooEarly(id);
        if (challengers[id].length == 0 && _verdict(att) == EvidenceVerdict.CONFIRMED)
            revert NoChallengesToResolve(id);
        uint256 up = upholdWeight[id];
        uint256 down = rejectWeight[id];
        // Snapshotted, so the owner cannot move the bar after the dispute is filed.
        uint256 needed = att.curatorQuorumWeight;
        if (up + down < needed) revert CuratorQuorumNotReached(id, up + down, needed);
        if (up == down) {
            // A tie is still a stall until the review deadline passes. `expireReview` is the
            // exit; refusing to tally here just forces the caller to use it.
            revert CuratorsSplit(id, up, down);
        }
        _resolve(id, att, up > down);
    }

    /// @notice Forces a stalled dispute to a ruling once the review window has closed. Reached
    /// quorum but tied, or failed to reach quorum at all. Defaults to rejecting the
    /// attestation's challengers and returning it to PENDING, so an unreachable or deadlocked
    /// panel can never slash a submitter who did nothing wrong.
    function expireReview(bytes32 id) external nonReentrant {
        Attestation storage att = _attestations[id];
        if (att.status != AttestationStatus.PENDING) revert NotPendingOrDisputed(id);
        if (block.timestamp <= att.reviewDeadline) revert ReviewNotExpirable(id);
        uint256 up = upholdWeight[id];
        uint256 down = rejectWeight[id];
        if (up + down >= att.curatorQuorumWeight && up != down) revert ReviewAlreadyResolved(id);

        // A REFUTED proof is a positive finding, not an absence of one, so expiry cannot
        // launder it: the submitter is still penalised.
        if (_verdict(att) == EvidenceVerdict.REFUTED && up >= down) {
            _resolve(id, att, true);
            return;
        }
        emit ReviewExpired(id, up, down);
        _resolve(id, att, false);
    }

    /// @dev Applies a ruling. `upheld` slashes the submitter and every signing attester;
    /// otherwise challenge bonds are forfeited and the attestation returns to PENDING.
    function _resolve(bytes32 id, Attestation storage att, bool upheld) internal {
        disputeUpheld[id] = upheld;
        emit Disputed(id, upholdWeight[id], rejectWeight[id]);
        if (upheld) {
            _penalise(id, att);
        } else {
            // Rejecting a dispute against a REFUTED/UNRESOLVED verdict means the panel is
            // overruling the machine. Without this the attestation could never finalize
            // (verdict blocks it), could never be re-challenged (window closed) and could
            // never be re-reviewed (curators already voted) — a permanent deadlock.
            if (_verdict(att) != EvidenceVerdict.CONFIRMED) att.panelOverride = true;
            _forfeitChallengeBonds(id);
            _clear(challengers[id]);
            emit DisputeResolved(id, false);
        }
    }

    /// @dev Burns the bond of every challenger when the challenge is thrown out. Without this
    /// leg a rejected challenge leaves the bond locked in the contract forever, and challenging
    /// stays free — which is exactly the griefing vector the bond exists to close.
    function _forfeitChallengeBonds(bytes32 id) internal {
        address[] storage ch = challengers[id];
        for (uint256 i = 0; i < ch.length;) {
            address c = ch[i];
            uint256 amount = challengeBond[c];
            _releaseLock(id, c);
            if (amount > 0) {
                challengeBond[c] = 0;
                outstandingChallengeBond -= amount;
                _burn(address(this), amount);
                emit ChallengerBondForfeited(id, c, amount);
            }
            unchecked {
                ++i;
            }
        }
    }

    function _clear(address[] storage arr) internal {
        while (arr.length > 0) {
            arr.pop();
        }
    }

    /// @dev Frees the bond a challenger committed to a now-settled challenge. Uses the
    /// per-attestation figure rather than the current `challengeBondAmount` so a mid-dispute
    /// setter change cannot leave the account permanently locked.
    function _releaseLock(bytes32 id, address c) internal {
        uint256 lock = challengeLock[id][c];
        if (lock > 0) {
            challengeLock[id][c] = 0;
            lockedChallengeBond[c] -= lock;
        }
    }

    /// @dev Burns the submitter's stake, slashes every attester who certified the fabrication,
    /// and escrows the unburned remainder plus forfeited challenge bonds for challengers to
    /// pull. Without the attester leg a colluding quorum signs a lie, the submitter is
    /// punished, and the signers are free. Settlement is deliberately O(signers) only:
    /// challenger payouts are pull-based so the transaction cost cannot be inflated by
    /// spamming challenges.
    function _penalise(bytes32 id, Attestation storage att) internal {
        uint256 burn = (att.stake * slashBps) / BPS_DENOMINATOR;
        uint256 remainder = att.stake - burn;
        att.status = AttestationStatus.SLASHED;
        // The whole stake leaves the submitter's liability: `burn` is destroyed and the remainder
        // becomes challenge-owed escrow, which is counted below. Subtracting only `burn` would
        // double-count the remainder as stake and as payout at the same time.
        totalStaked -= att.stake;
        att.stake = 0;
        if (burn > 0) _burn(address(this), burn);
        emit DisputeResolved(id, true);
        emit AttestationSlashed(id, att.submitter, burn);

        address[] storage sg = signers[id];
        for (uint256 i = 0; i < sg.length;) {
            address a = sg[i];
            uint256 pen = (attesterBond[a] * attesterSlashBps) / BPS_DENOMINATOR;
            if (pen > 0) {
                attesterBond[a] -= pen;
                outstandingAttesterBond -= pen;
                _burn(address(this), pen);
                emit AttesterSlashed(id, a, pen);
            }
            unchecked {
                ++i;
            }
        }

        // Forfeited bonds from challengers whose dispute lost, added to the payout pool.
        uint256 forfeited;
        address[] storage ch = challengers[id];
        uint256 n = ch.length;
        for (uint256 i = 0; i < n;) {
            forfeited += challengeBond[ch[i]];
            unchecked {
                ++i;
            }
        }
        uint256 pool = remainder + forfeited;
        uint256 each = n > 0 ? pool / n : 0;

        // Assign each challenger its own entitlement. A single shared pool figure cannot
        // represent N independent claims, because the first claimant zeroes it and the
        // remaining challengers revert with the rest of the forfeiture stranded.
        for (uint256 i = 0; i < n;) {
            address c = ch[i];
            _releaseLock(id, c);
            payoutShare[id][c] = each;
            challengeBond[c] = 0;
            unchecked {
                ++i;
            }
        }
        outstandingChallengeBond -= forfeited;

        // Integer division leaves dust. It stays in the contract rather than being silently
        // burned, so the escrow total remains exactly reconcilable against the held balance.
        payoutPool[id] = each * n;
        totalPayoutEscrow += each * n;
        emit PoolSeeded(id, each, n);
        _clear(ch);
    }

    /// @notice Pulls a challenger's share of the settlement pool. Pull-based so a large
    /// challenger set cannot make settlement unspendable.
    function claimChallengeReward(bytes32 id) external nonReentrant {
        if (!wasChallenger[id][msg.sender]) revert NotAChallenger(id, msg.sender);
        if (disputeUpheld[id] != true) revert NothingToClaim(id, msg.sender);
        if (hasClaimed[id][msg.sender]) revert ClaimAlreadyMade(id, msg.sender);
        uint256 amount = payoutShare[id][msg.sender];
        if (amount == 0) revert NothingToClaim(id, msg.sender);
        hasClaimed[id][msg.sender] = true;
        payoutShare[id][msg.sender] = 0;
        payoutPool[id] -= amount;
        totalPayoutEscrow -= amount;
        _update(address(this), msg.sender, amount);
        emit ChallengeRewardClaimed(id, msg.sender, amount);
    }

    /// @notice Verifies a candidate pre-image against the committed content hash. Stateless: it
    /// records nothing, so a wrong guess costs the caller a transaction and nothing else.
/// This is the safe form of reveal — compare the returned flag rather than trusting storage.
    function checkSecret(bytes32 id, bytes32 candidate) external view returns (bool valid) {
        Attestation storage att = _attestations[id];
        return keccak256(abi.encode(candidate, att.submitter)) == att.contentHash;
    }

    /// @notice Discloses the pre-image after the challenge window has closed, so a curator can
    /// audit it. Restricted to a challenger of this attestation or any curator, because
    /// unrestricted it destroys the confidentiality the commit-reveal exists for during the
    /// window anyone can call.
    ///
    /// @dev Verifies and emits without mutating. The earlier version overwrote `att.secret`
    /// unconditionally, so any address could clobber the submitter's secret with garbage. The
    /// first valid reveal is recorded once; a later wrong guess cannot replace it.
    function revealSecret(bytes32 id, bytes32 candidate) external {
        Attestation storage att = _attestations[id];
        if (att.status == AttestationStatus.SLASHED) revert AttestationNotFinalized(id);
        if (att.status == AttestationStatus.FINALIZED) revert AttestationNotFinalized(id);
        if (block.timestamp <= att.challengeDeadline) revert ChallengeWindowOpen(id);
        if (wasChallenger[id][msg.sender] != true && !_isCurator(msg.sender))
            revert NotAuthorizedRevealer(id, msg.sender);

        bool valid = keccak256(abi.encode(candidate, att.submitter)) == att.contentHash;
        if (valid) {
            if (att.secretRevealed) revert AlreadyRevealed(id);
            att.secret = candidate;
            att.secretRevealed = true;
        }
        emit SecretRevealed(id, att.contentHash, valid);
    }

    function _isCurator(address account) internal view returns (bool) {
        Attester storage c = _curators[account];
        return c.account != address(0) && c.active;
    }

    /// @notice The machine's opinion on an attestation. CONFIRMED when no verifier is set.
    /// Read this directly if you want the raw verdict; it is the same value `finalizeAttestation`
    /// gates on, and it never reverts.
    function evidenceVerdict(bytes32 id) external view returns (EvidenceVerdict) {
        return _verdict(_attestations[id]);
    }

    /// @notice Total tokens the contract owes to third parties. Never burnable.
    function totalLiabilities() public view returns (uint256) {
        return totalStaked + totalPayoutEscrow + outstandingAttesterBond + outstandingChallengeBond;
    }

    /// @notice Tokens held that no one is owed to. The only thing the owner may burn.
    /// Burning anything above this would consume live stakes or bonds and leave the
    /// contract insolvent while still reporting those liabilities as outstanding.
    function excessBalance() public view returns (uint256) {
        uint256 held = balanceOf(address(this));
        uint256 owed = totalLiabilities();
        return held > owed ? held - owed : 0;
    }

    /// @notice Burns only the unbacked remainder, so slashed stake cannot be turned into a
    /// rug on pending stakes or live bonds.
    function recoverExcessStake(uint256 amount) external onlyOwner nonReentrant {
        uint256 excess = excessBalance();
        if (amount > excess) revert NothingToRecover(amount, excess);
        _burn(address(this), amount);
    }
}
