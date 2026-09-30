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
    error NotCurator(address account);
    error CuratorInactive(address account);
    error AlreadyVoted(bytes32 id, address curator);
    error CuratorVoteTooEarly(bytes32 id);
    error CuratorQuorumNotReached(bytes32 id, uint256 have, uint256 need);
    error CuratorsSplit(bytes32 id, uint256 upholdWeight, uint256 rejectWeight);
    error TooManySigners(bytes32 id);
    error TooManyChallengers(bytes32 id);
    error ClaimAlreadyMade(bytes32 id, address account);
    error NothingToClaim(bytes32 id, address account);
    error NotAChallenger(bytes32 id, address account);
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
    event ChallengerBondForfeited(bytes32 indexed id, address indexed challenger, uint256 amount);
    event SecretRevealed(bytes32 indexed id, bytes32 contentHash, bool valid);
    event VerifierSet(address indexed verifier);

    uint128 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant CHALLENGE_WINDOW = 2 days;

    /// @dev Hard caps so settlement cost is bounded regardless of committee size.
    uint256 public constant MAX_SIGNERS = 50;
    uint256 public constant MAX_CHALLENGERS = 50;

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
    mapping(address => Attester) private _curators;
    mapping(bytes32 => mapping(address => bool)) public curatorVote;
    mapping(bytes32 => uint128) public upholdWeight;
    mapping(bytes32 => uint128) public rejectWeight;
    mapping(bytes32 => mapping(address => bool)) public hasClaimed;
    mapping(bytes32 => mapping(address => bool)) public wasChallenger;
    uint256 public totalCuratorWeight;
    uint256 public challengeBondAmount;
    mapping(address => uint256) public challengeBond;
    mapping(bytes32 => uint256) public payoutPool;

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
    }

    function setChallengeBondAmount(uint256 amount) external onlyOwner {
        challengeBondAmount = amount;
    }

    function withdrawChallengeBond() external nonReentrant {
        uint256 amount = challengeBond[msg.sender];
        if (amount == 0) revert NoBondToWithdraw();
        challengeBond[msg.sender] = 0;
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
        if (signers[id].length >= MAX_SIGNERS) revert TooManySigners(id);
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
        if (challengers[id].length >= MAX_CHALLENGERS) revert TooManyChallengers(id);
        uint256 bond = challengeBond[msg.sender];
        if (bond < challengeBondAmount)
            revert BondBelowRequired(bond, challengeBondAmount);
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
        if (challengers[id].length == 0) revert NoChallengesToResolve(id);
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
        if (challengers[id].length == 0) revert NoChallengesToResolve(id);
        uint256 up = upholdWeight[id];
        uint256 down = rejectWeight[id];
        if (up + down < curatorQuorumWeight())
            revert CuratorQuorumNotReached(id, up + down, curatorQuorumWeight());
        if (up == down) revert CuratorsSplit(id, up, down);
        disputeUpheld[id] = up > down;
        emit Disputed(id, up, down);
        if (up > down) {
            _penalise(id, att);
        } else {
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
            if (amount > 0) {
                challengeBond[c] = 0;
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
        uint256 totalChallengers = n;
        uint256 each = n > 0 ? pool / n : 0;
        payoutPool[id] = each;
        for (uint256 i = 0; i < n;) {
            challengeBond[ch[i]] = 0;
            unchecked {
                ++i;
            }
        }
        emit PoolSeeded(id, each, totalChallengers);
        _clear(ch);
    }

    /// @notice Pulls a challenger's share of the settlement pool. Pull-based so a large
    /// challenger set cannot make settlement unspendable.
    function claimChallengeReward(bytes32 id) external nonReentrant {
        if (!wasChallenger[id][msg.sender]) revert NotAChallenger(id, msg.sender);
        if (hasClaimed[id][msg.sender]) revert ClaimAlreadyMade(id, msg.sender);
        if (disputeUpheld[id] != true) revert NothingToClaim(id, msg.sender);
        uint256 amount = payoutPool[id];
        if (amount == 0) revert NothingToClaim(id, msg.sender);
        hasClaimed[id][msg.sender] = true;
        payoutPool[id] = 0;
        _update(address(this), msg.sender, amount);
        emit ChallengeRewardClaimed(id, msg.sender, amount);
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
