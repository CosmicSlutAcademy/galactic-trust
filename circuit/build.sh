#!/bin/bash
# Build the Groth16 artifacts for evidence.circom and export the Solidity verifier.
#
# Regenerating the proving/verifying keys invalidates every proof already submitted, so
# `circuit_final.zkey` and `verification_key.json` are committed. Re-run this only when
# the circuit itself changes.
set -euo pipefail

CIRCOM="$HOME/.local/bin/circom"
SNARKJS="$HOME/.localtools/snarkjs/node_modules/.bin/snarkjs"
CIRCOMLIB="$HOME/.localtools/circomlib-2.0.5/circuits"

cd "$HOME/galactic-trust/circuit" || exit 1

echo "== compile =="
"$CIRCOM" evidence.circom --r1cs --wasm --sym -l "$CIRCOMLIB" -o .

if [ ! -f circuit_final.zkey ]; then
  echo "== powers of tau (2^14 = 16384 constraints; this circuit needs 7513) =="
  "$SNARKJS" powersoftau new bn128 14 pot14_0000.ptau -v
  "$SNARKJS" powersoftau contribute pot14_0000.ptau pot14_0001.ptau \
    --name="GLT ptau contribution" -e="dev-only-seed" -v
  # The beacon takes (hash, numIterationsExp) — omitting the iteration count is what
  # "Invalid number of parameters" means, and the hash alone is not enough.
  "$SNARKJS" powersoftau beacon pot14_0001.ptau pot14_final.ptau \
    0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20 10 -v

  echo "== phase2 prepare =="
  # Required before groth16 setup. Without it the error is "Powers of tau is not
  # prepared" and a zero-byte circuit_0000.zkey is left behind.
  "$SNARKJS" powersoftau prepare phase2 pot14_final.ptau pot14_final_phase2.ptau -v

  echo "== groth16 setup =="
  "$SNARKJS" groth16 setup evidence.r1cs pot14_final_phase2.ptau circuit_0000.zkey
  "$SNARKJS" zkey contribute circuit_0000.zkey circuit_final.zkey \
    --name="GLT circuit contribution" -e="dev-only-zkey-seed" -v
  "$SNARKJS" zkey export verificationkey circuit_final.zkey verification_key.json
  rm -f pot14_0000.ptau pot14_0001.ptau pot14_final.ptau pot14_final_phase2.ptau circuit_0000.zkey
fi

echo "== export Solidity verifier =="
"$SNARKJS" zkey export solidityverifier circuit_final.zkey Verifier.sol

echo "== done =="
ls -la circuit_final.zkey verification_key.json Verifier.sol