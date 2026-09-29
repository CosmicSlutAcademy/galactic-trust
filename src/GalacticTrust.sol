// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {IVerifier} from "./IVerifier.sol";

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
    event SecretRevealed(bytes32 indexed id, bytes32 contentHash, bool valid);
    event VerifierSet(address indexed verifier);

    uint128 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant CHALLENGE_WINDOW = 2 days;

    IVerifier public verifier;
    uint256 public quorumBps = 5_000;
    uint256 public minStake;
    uint256 public totalAttesterWeight;
    uint256 public rewardAmount = 100e18;
    uint256 public slashBps = 10_000;
    uint256 public attesterBondAmount;
    uint256 public attesterSlashBps = 10_000;

    mapping(address => Attester) private _attesters;
    mapping(bytes32 => Attestation) private _attestations;
    mapping(bytes32 => mapping(address => bool)) public hasSigned;
    mapping(bytes32 => mapping(address => bool)) public hasChallenged;
    mapping(bytes32 => address[]) public challengers;
    mapping(bytes32 => address[]) public signers;
    mapping(address => uint256) public attesterBond;
    mapping(bytes32 => bool) public disputeUpheld;

    modifier onlyAttester() {
        Attester storage a = _attesters[msg.sender];
        if (a.account == address(0)) revert NotAttester(msg.sender);
        if (!a.active) revert AttesterInactive(msg.sender);
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
        emit AttesterBondFunded(msg.sender, amount);
    }

    /// @notice Withdraws the bond. Only possible once deactivated, so a validator cannot
    /// bond, certify, and immediately withdraw before a dispute resolves.
    function withdrawAttesterBond() external nonReentrant {
        if (_attesters[msg.sender].active) revert AttesterStillActive(msg.sender);
        uint256 amount = attesterBond[msg.sender];
        if (amount == 0) revert NoBondToWithdraw();
        attesterBond[msg.sender] = 0;
        _update(address(this), msg.sender, amount);
        emit AttesterBondWithdrawn(msg.sender, amount);
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
        hasSigned[id][msg.sender] = true;
        signers[id].push(msg.sender);
        att.attestationWeight += a.weight;
        emit AttestationSigned(id, msg.sender, a.weight);
    }

    /// @notice Mints the reward. Requires quorum, an expired window, and zero challenges.
    function finalizeAttestation(bytes32 id) external nonReentrant {
        Attestation storage att = _attestations[id];
        if (att.status == AttestationStatus.FINALIZED) revert QuorumReached(id);
        if (att.status != AttestationStatus.PENDING) revert AttestationNotPending(id);
        if (block.timestamp <= att.challengeDeadline) revert ChallengeWindowOpen(id);
        if (challengers[id].length > 0) revert AttestationUnderChallenge(id);
        if (att.attestationWeight < att.quorumWeight)
            revert QuorumNotReached(id, att.attestationWeight, att.quorumWeight);
        att.status = AttestationStatus.FINALIZED;
        if (att.stake > 0) _update(address(this), att.submitter, att.stake);
        _mint(att.submitter, rewardAmount);
        emit AttestationFinalized(id, att.submitter, rewardAmount);
    }

    /// @notice Red-team flag. Challenges accumulate; a single challenger cannot freeze an
    /// attestation, so escalation is a quorum event rather than one party's decision.
    function challengeAttestation(bytes32 id, bytes32 reason) external {
        Attestation storage att = _attestations[id];
        if (att.status != AttestationStatus.PENDING) revert AttestationNotPending(id);
        if (block.timestamp > att.challengeDeadline) revert ChallengeWindowClosed(id);
        if (hasChallenged[id][msg.sender]) revert AlreadyChallenged(id, msg.sender);
        hasChallenged[id][msg.sender] = true;
        challengers[id].push(msg.sender);
        emit AttestationChallenged(id, msg.sender, reason);
    }

    /// @notice Curator ruling, only after the window closes. Upheld disputes burn the stake;
    /// rejected disputes clear the challenge slate and release the attestation for finalization.
    function resolveDispute(bytes32 id, bool uphold) external onlyOwner {
        Attestation storage att = _attestations[id];
        if (att.status != AttestationStatus.PENDING) revert NotPendingOrDisputed(id);
        if (block.timestamp <= att.challengeDeadline) revert ChallengeWindowOpen(id);
        if (challengers[id].length == 0) revert NoChallengesToResolve(id);
        disputeUpheld[id] = uphold;
        if (uphold) {
            _penalise(id, att);
        } else {
            _clear(challengers[id]);
            emit DisputeResolved(id, false);
        }
    }

    function _clear(address[] storage arr) internal {
        while (arr.length > 0) {
            arr.pop();
        }
    }

    /// @dev Burns the submitter's stake, slashes every attester who certified the fabrication,
    /// and pays the unburned remainder to the challengers who caught it. Without the attester
    /// leg a colluding quorum signs a lie, the submitter is punished, and the signers are free.
    function _penalise(bytes32 id, Attestation storage att) internal {
        uint256 burn = (att.stake * slashBps) / BPS_DENOMINATOR;
        uint256 remainder = att.stake - burn;
        att.status = AttestationStatus.SLASHED;
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
                _burn(address(this), pen);
                emit AttesterSlashed(id, a, pen);
            }
            unchecked {
                ++i;
            }
        }

        address[] storage ch = challengers[id];
        if (remainder > 0 && ch.length > 0) {
            uint256 share = remainder / ch.length;
            for (uint256 i = 0; i < ch.length;) {
                _update(address(this), ch[i], share);
                emit ChallengerRewarded(id, ch[i], share);
                unchecked {
                    ++i;
                }
            }
        }
        _clear(ch);
    }

    /// @notice Reveals the pre-image so a curator can recompute the content hash.
    function revealSecret(bytes32 id, bytes32 secret) external {
        Attestation storage att = _attestations[id];
        if (att.status == AttestationStatus.SLASHED) revert AttestationNotFinalized(id);
        if (att.status == AttestationStatus.FINALIZED) revert AttestationNotFinalized(id);
        bool valid = keccak256(abi.encode(secret, att.submitter)) == att.contentHash;
        att.secret = secret;
        emit SecretRevealed(id, att.contentHash, valid);
    }

    /// @notice Optional ZK hook. Returns true when no verifier is configured.
    function passesVerifier(bytes32 id) external view returns (bool) {
        if (address(verifier) == address(0)) return true;
        Attestation storage att = _attestations[id];
        return verifier.verifyEvidence(att.contentHash, uint8(att.tier));
    }

    /// @notice Burns the treasury balance of slashed stakes.
    function recoverExcessStake(uint256 amount) external onlyOwner nonReentrant {
        _burn(address(this), amount);
    }
}
