// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Three-state evidence verdict rather than a boolean.
/// A boolean collapses "the proof says this is false" and "the proof system is broken"
/// into one value. Treating those identically is how a verifier outage becomes either a
/// silent mint or a total freeze. UNRESOLVED exists to route the second case to humans
/// instead of letting it decide anything.
enum EvidenceVerdict {
    UNRESOLVED,
    CONFIRMED,
    REFUTED
}

interface IVerifier {
    /// @dev Must be a pure function of on-chain state. A verifier that reverts or consumes
    /// gas unpredictably can stall finalization for every attestation, so the caller treats
    /// a revert as UNRESOLVED rather than propagating it.
    function verifyEvidence(bytes32 evidenceHash, uint8 tier) external view returns (EvidenceVerdict);
}