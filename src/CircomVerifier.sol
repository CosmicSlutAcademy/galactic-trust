// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVerifier, EvidenceVerdict} from "./IVerifier.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Groth16Verifier} from "../circuit/Verifier.sol";

/*
    A real proof system behind the tri-state gate.

    `circuit/evidence.circom` proves that a holder of an approved device signing key
    signed a sensor reading, and that the reading sits inside the numeric envelope its
    declared tier allows. This contract is the on-chain half: it checks the Groth16
    pairing, records the verdict, and answers `IVerifier`.

    What a verdict means here, precisely:

      CONFIRMED  an approved device signed a reading that satisfies its tier's rules
      REFUTED    an approved device signed a reading that breaks them
      UNRESOLVED no approved device has said anything provable about this evidence

    This does NOT mean the reading is true. A device that lies inside its envelope gets
    a valid CONFIRMED. See SESSION.md §2 item 2 — GLT asserts stakes and the dispute
    record, never reality. The gate catches *out-of-spec* evidence cheaply and gives the
    curator panel something better than silence to reason about.

    Why the verdict is stored rather than recomputed on every read
    --------------------------------------------------------------
    `verifyEvidence` is `view`, per IVerifier, so it cannot take a proof as an argument,
    and it cannot afford a ~300k-gas pairing check on every read — GLT calls it from
    finalize, tally, expire and resolve. So the pairing runs once, in `submitProof`, and
    only its outcome is persisted. The stored value is not a trusted assertion: it can
    only be written by a call that passed the pairing check.

    The device registry is the actual trust boundary
    -----------------------------------------------
    The circuit proves *a* signature, not *whose*. Without `approvedDevice`, anyone could
    generate a valid REFUTED proof for anyone else's evidenceHash and close the gate at
    will. The circuit binds `deviceKeyHash === Poseidon(Ax, Ay)` so the key claimed in
    the public signals is the key that actually signed — otherwise a prover would sign
    with a key of their own and then assert an approved hash. Those two constraints
    together are what make `approveDevice` meaningful rather than decorative.
*/
contract CircomVerifier is IVerifier, Groth16Verifier, Ownable {
    error NotInField(uint256 value);
    error TierOutOfRange(uint8 tier);
    error DeviceNotApproved(uint256 deviceKeyHash);
    error InvalidVerdict(uint8 verdict);
    error ProofAlreadySubmitted(bytes32 evidenceHash, uint8 tier);

    event DeviceApproved(uint256 indexed deviceKeyHash);
    event DeviceRevoked(uint256 indexed deviceKeyHash);
    event ProofSubmitted(bytes32 indexed evidenceHash, uint8 indexed tier, uint8 verdict);

    /// The BN254 scalar field. A bytes32 at or above this does not round-trip through the
    /// witness: `hash` and `hash - SNARK_FIELD` encode to the same field element, so two
    /// distinct pieces of evidence would share a verdict. The circuit cannot express this
    /// constant (circom 2 removed global `var`), so it is enforced here — the only place
    /// a bytes32 enters the system.
    uint256 private constant SNARK_FIELD =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    /// Matches `EvidenceTier` in GalacticTrust: UNVERIFIED(0) through R5(6).
    uint8 private constant MAX_TIER = 6;

    struct Record {
        bool present;
        uint8 verdict;
    }

    /// @dev Governed registry of device signing keys, keyed by the Poseidon hash of the
    /// BabyJub public key. `uint256`, not `bytes32`: Poseidon outputs a field element,
    /// and the circuit constrains the public signal to it directly.
    mapping(uint256 => bool) public approvedDevice;

    mapping(bytes32 => Record) private records;

    constructor(address initialOwner) Ownable(initialOwner) {}

    // --- governance -----------------------------------------------------------------

    function approveDevice(uint256 deviceKeyHash) external onlyOwner {
        approvedDevice[deviceKeyHash] = true;
        emit DeviceApproved(deviceKeyHash);
    }

    function revokeDevice(uint256 deviceKeyHash) external onlyOwner {
        approvedDevice[deviceKeyHash] = false;
        emit DeviceRevoked(deviceKeyHash);
    }

    // --- proof submission -----------------------------------------------------------

    /// @notice Verify a Groth16 proof and, if it holds, record its verdict.
    ///
    /// Permissionless on purpose: the owner controls which devices are trusted, not which
    /// proofs are admitted. Gating submission behind the owner would hand one key the
    /// ability to suppress a REFUTED — the same single-point-of-failure shape as letting
    /// the owner settle disputes directly.
    ///
    /// First write wins. A device cannot retract a REFUTED by re-submitting a conformant
    /// reading, and nobody can flip a verdict back and forth around a finalization. That
    /// costs a device the ability to correct a mistaken proof, which is the right way
    /// round: the reading it signed really was out of spec.
    ///
    /// A malformed or non-satisfying proof reverts and stores nothing. It is not recorded
    /// as UNRESOLVED, because absence already means UNRESOLVED — recording garbage would
    /// only add a way to make a claim look answered.
    function submitProof(
        bytes32 evidenceHash,
        uint8 tier,
        uint8 verdict,
        uint256 deviceKeyHash,
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c
    ) external {
        if (!_inField(evidenceHash)) revert NotInField(uint256(evidenceHash));
        if (tier > MAX_TIER) revert TierOutOfRange(tier);
        if (verdict > 1) revert InvalidVerdict(verdict);
        if (!approvedDevice[deviceKeyHash]) revert DeviceNotApproved(deviceKeyHash);

        bytes32 slot = _slot(evidenceHash, tier);
        if (records[slot].present) revert ProofAlreadySubmitted(evidenceHash, tier);

        uint256[4] memory publicSignals;
        publicSignals[0] = uint256(evidenceHash);
        publicSignals[1] = tier;
        publicSignals[2] = verdict;
        publicSignals[3] = deviceKeyHash;

        // The pairing is the whole check. `verdict` is not taken on trust: the circuit
        // pins it to the envelope check on the private witness, so a prover can only
        // present this verdict if it genuinely signed a reading with that property.
        //
        // `this.verifyProof(...)` must stay an *external* call. The generated verifier reads
        // its four arguments with `calldataload` in inline assembly, so a memory pointer
        // passed by an internal call is not a calldata offset — it is garbage, and every
        // proof is rejected. This was the cause of a day of "proof rejected" on a proof
        // `groth16.verify` accepted. Do not "simplify" this into a direct call: Solidity
        // will refuse it (memory -> calldata), and the obvious wrapper that does compile
        // silently reintroduces the bug.
        require(this.verifyProof(a, b, c, publicSignals), "proof rejected");

        records[slot] = Record({present: true, verdict: verdict});
        emit ProofSubmitted(evidenceHash, tier, verdict);
    }

    // --- IVerifier ------------------------------------------------------------------

    /// @notice CONFIRMED or REFUTED once an approved device has proved something about
    /// this evidence, UNRESOLVED until then. Never reverts: GLT reads this inside a
    /// try/catch and maps a revert to UNRESOLVED, and a stored-record read cannot fail.
    function verifyEvidence(bytes32 evidenceHash, uint8 tier) external view returns (EvidenceVerdict) {
        Record storage rec = records[_slot(evidenceHash, tier)];
        if (!rec.present) return EvidenceVerdict.UNRESOLVED;
        return rec.verdict == 1 ? EvidenceVerdict.CONFIRMED : EvidenceVerdict.REFUTED;
    }

    function hasProof(bytes32 evidenceHash, uint8 tier) external view returns (bool) {
        return records[_slot(evidenceHash, tier)].present;
    }

    /// @notice Whether this evidence hash can be proven about at all.
    ///
    /// The BN254 field is ~254 bits, not 256, so a bytes32 above the field prime has no
    /// distinct field representation: it would collide with `hash - SNARK_FIELD`. Those
    /// hashes are refused rather than reduced, because reducing would let one attestation
    /// inherit another's verdict.
    ///
    /// This matters in practice. About 81% of uniformly random bytes32 values — which
    /// includes anything produced by `keccak256` — are >= the field prime, so a submitter
    /// that picks its `contentHash` without checking will find every proof submission
    /// reverting with `NotInField`. Nothing is lost: the verdict stays UNRESOLVED, which
    /// routes the attestation to the curator panel rather than minting. But a claim that
    /// was meant to be machine-checkable silently never becomes so, so integrators should
    /// call this before choosing a hash.
    function isProvable(bytes32 evidenceHash) external pure returns (bool) {
        return _inField(evidenceHash);
    }

    // --- internals ------------------------------------------------------------------

    function _slot(bytes32 evidenceHash, uint8 tier) private pure returns (bytes32) {
        return keccak256(abi.encode(evidenceHash, tier));
    }

    function _inField(bytes32 evidenceHash) private pure returns (bool) {
        return uint256(evidenceHash) < SNARK_FIELD;
    }
}
