// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IVerifier {
    function verifyEvidence(bytes32 evidenceHash, uint8 tier) external view returns (bool);
}
