// Witness/proof generator for evidence.circom.
//
// Produces the EdDSA signature over the Poseidon message the circuit expects
// (deviceId, reading, timestamp, contentHash, tier), then a Groth16 proof. The fixtures
// this writes are what test/CircomVerifier.t.sol asserts against, so they are committed
// rather than regenerated during `forge test` — proving is far too slow to run per-test.
const fs = require("fs");
const path = require("path");
const os = require("os");
// circomlibjs and snarkjs live in ~/.localtools/snarkjs rather than in this repo: they
// are build-time tooling, not a dependency of the contract. NODE_PATH points here.
const NODE_MODULES = path.join(os.homedir(), ".localtools", "snarkjs", "node_modules");
const { buildEddsa, buildBabyjub, buildPoseidon } = require(path.join(NODE_MODULES, "circomlibjs"));
const snarkjs = require(path.join(NODE_MODULES, "snarkjs"));

const ROOT = path.join(os.homedir(), "galactic-trust", "circuit");
const WASM = path.join(ROOT, "evidence_js", "evidence.wasm");
const ZKEY = path.join(ROOT, "circuit_final.zkey");
const VKEY = path.join(ROOT, "verification_key.json");

// Must match TIER_HI in evidence.circom.
const TIER_HI = [100, 100, 1000, 10000, 100000, 1000000, 4294967295];

async function generate({ deviceSeed, deviceId, reading, timestamp, contentHash, tier }) {
  const eddsa = await buildEddsa();
  const poseidon = await buildPoseidon();

  const priv = eddsa.pruneBuffer(eddsa.pruneBuffer(Buffer.from(deviceSeed, "hex")));
  const babyJub = await buildBabyjub();
  const pub = eddsa.prv2pub(priv);

  // prv2pub returns Montgomery-form coordinates as Uint8Array. The circuit wants the
  // affine field elements, so unwrap them before hashing or the numbers are garbage.
  const Ax = babyJub.F.toObject(pub[0]);
  const Ay = babyJub.F.toObject(pub[1]);

  // This must equal Poseidon(Ax, Ay) in the circuit, since deviceKeyHash is public and
  // constrained to it.
  //
  // The F.toObject conversion matters and is not cosmetic: circomlibjs's poseidon returns
  // a Uint8Array (montgomery form), and interpolating it straight into `.toString()` gives
  // "47,48,34,..." — a comma-joined byte list that the witness calculator rejects.
  const deviceKeyHash = babyJub.F.toObject(poseidon([Ax, Ay]));

  // `contentHash` is a HEX string. `BigInt("1111...1111")` would read it as DECIMAL and
  // commit to an entirely different number, which then fails the pairing check on-chain
  // with a bare "proof rejected" and no other symptom. Parse it as hex, once, here.
  const contentHashField = BigInt("0x" + contentHash);

  const M = poseidon([
    BigInt(deviceId),
    BigInt(reading),
    BigInt(timestamp),
    contentHashField,
    BigInt(tier),
  ]);

  // signPoseidon takes the message as a single field element: it hashes Poseidon-5 over
  // (R8x, R8y, Ax, Ay, msg), which is exactly what EdDSAPoseidonVerifier does in-circuit.
  const sig = eddsa.signPoseidon(priv, M);
  // verifyPoseidon consumes the point as prv2pub returned it. Passing F.toObject output
  // instead throws inside ffjavascript, so the two representations must not be mixed.
  if (!eddsa.verifyPoseidon(M, sig, pub)) {
    throw new Error("signPoseidon produced a signature its own verifier rejects");
  }

  const input = {
    contentHash: contentHashField.toString(),
    tier: BigInt(tier).toString(),
    verdict: BigInt(reading <= TIER_HI[tier] ? 1 : 0).toString(),
    deviceKeyHash: deviceKeyHash.toString(),
    deviceId: BigInt(deviceId).toString(),
    reading: BigInt(reading).toString(),
    timestamp: BigInt(timestamp).toString(),
    Ax: Ax.toString(),
    Ay: Ay.toString(),
    S: sig.S.toString(),
    // sig.R8 entries are Uint8Array. Calling .toString() on them yields the comma-joined
    // byte list ("47,48,34,..."), which the witness calculator rejects as not a BigInt.
    R8x: babyJub.F.toObject(sig.R8[0]).toString(),
    R8y: babyJub.F.toObject(sig.R8[1]).toString(),
  };

  const { proof, publicSignals } = await snarkjs.groth16.fullProve(input, WASM, ZKEY);
  const verified = await snarkjs.groth16.verify(
    JSON.parse(fs.readFileSync(VKEY, "utf8")),
    publicSignals,
    proof
  );
  if (!verified) throw new Error("groth16.verify rejected a proof fullProve just produced");

  // The evidence hash the circuit actually committed to must be the one the caller asked
  // for. This check exists because `BigInt(hexString)` reads as decimal and silently
  // produces a different number, which shows up on-chain only as "proof rejected".
  if (BigInt(publicSignals[0]) !== contentHashField) {
    throw new Error(
      `publicSignals[0]=${publicSignals[0]} but contentHashField=${contentHashField}`
    );
  }

  // Take the proof encoding from snarkjs itself rather than copying pi_a/pi_b/pi_c by
  // hand. `pi_b` is NOT the layout the generated Solidity verifier wants: each G2 row has
  // its coordinates flipped, and `exportSolidityCallData` is what does that flip. Copying
  // pi_b verbatim produces a proof that `groth16.verify` accepts and the EVM rejects.
  // Verified: with pi_b copied raw, every proof came back "proof rejected".
  // `exportSolidityCallData` is async and returns four JSON arrays joined by commas.
  const calldata = await snarkjs.groth16.exportSolidityCallData(proof, publicSignals);
  const words = String(calldata).match(/0x[0-9a-fA-F]+/g).map((w) => BigInt(w).toString());
  if (words.length !== 12) {
    throw new Error(`expected 12 field elements (a2 + b4 + c2 + signals4), got ${words.length}`);
  }

  const encoded = {
    a: [words[0], words[1]],
    b: [
      [words[2], words[3]],
      [words[4], words[5]],
    ],
    c: [words[6], words[7]],
  };

  if (encoded.a[0] !== proof.pi_a[0].toString() || encoded.a[1] !== proof.pi_a[1].toString()) {
    throw new Error("a coordinates changed during encoding — the layout assumption is wrong");
  }
  if (encoded.b[0][0] === proof.pi_b[0][0].toString() && encoded.b[0][1] === proof.pi_b[0][1].toString()) {
    throw new Error("b row was not flipped — the G2 coordinate order assumption is wrong");
  }

  // `reading` is returned as a Number only for readability in the fixture; the tests compare
  // it, and 5000 / 99999 are far inside the safe-integer range.
  return {
    deviceKeyHash: deviceKeyHash.toString(),
    tier,
    reading: Number(reading),
    // Decimal, matching how publicSignals is stored, so the Solidity test can read both with
    // `vm.parseJsonUint` and cast.
    contentHash: contentHashField.toString(),
    publicSignals,
    // The full witness input, kept so the fixture can be regenerated without re-deriving
    // the private scalars by hand — and so a failure can be reproduced exactly.
    witnessInput: input,
    proof: encoded,
  };
}

async function main() {
  const DEVICE_A = "00".repeat(31) + "01";
  const DEVICE_B = "00".repeat(31) + "02";

  const CONFIRMED_HASH = "1111111111111111111111111111111111111111111111111111111111111111";
  const REFUTED_HASH = "2222222222222222222222222222222222222222222222222222222222222222";
  const TS = 1757000000;

  const fixtures = {
    // Tier 3 (R2) accepts readings up to 10000.
    confirmed: await generate({
      deviceSeed: DEVICE_A,
      deviceId: 42,
      reading: 5000,
      timestamp: TS,
      contentHash: CONFIRMED_HASH,
      tier: 3,
    }),
    refuted: await generate({
      deviceSeed: DEVICE_A,
      deviceId: 42,
      reading: 99999,
      timestamp: TS,
      contentHash: REFUTED_HASH,
      tier: 3,
    }),
    // Same reading, same signer, same evidence hash as `confirmed`, but declared
    // UNVERIFIED (ceiling 100) instead of R2 (ceiling 10000). Reading 5000 clears one and
    // breaks the other, so these two fixtures together are what prove the tier is
    // load-bearing rather than decorative. They must share CONFIRMED_HASH for that to
    // mean anything, which is why they are generated adjacently and cross-checked in
    // test_TierIsLoadBearingNotDecorative.
    refutedTier0: await generate({
      deviceSeed: DEVICE_A,
      deviceId: 42,
      reading: 5000,
      timestamp: TS,
      contentHash: CONFIRMED_HASH,
      tier: 0,
    }),
    // A second device key, never approved. Same shape as `confirmed`.
    unapproved: await generate({
      deviceSeed: DEVICE_B,
      deviceId: 77,
      reading: 5000,
      timestamp: TS,
      contentHash: CONFIRMED_HASH,
      tier: 3,
    }),
  };

  // Sanity: the four public signals, in circuit declaration order.
  fixtures.expectedPublicSignals = {
    confirmed: [CONFIRMED_HASH, "3", "1"],
    refuted: [REFUTED_HASH, "3", "0"],
  };

  const out = path.join(os.homedir(), "galactic-trust", "test", "fixtures", "proofs.json");
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, JSON.stringify(fixtures, null, 2) + "\n");

  console.log("wrote", out);
  for (const [name, f] of Object.entries(fixtures)) {
    if (name === "expectedPublicSignals") continue;
    console.log(` ${name.padEnd(12)} tier=${f.tier} reading=${f.reading} publicSignals=[${f.publicSignals.join(", ")}]`);
  }
  if (fixtures.unapproved.deviceKeyHash === fixtures.confirmed.deviceKeyHash) {
    throw new Error("device A and device B produced the same key hash — fixtures are useless");
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});