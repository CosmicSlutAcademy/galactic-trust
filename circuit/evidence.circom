pragma circom 2.0.0;

include "eddsaposeidon.circom";
include "comparators.circom";
include "bitify.circom";
include "poseidon.circom";

/*
    Evidence well-formedness for GLT.

    What this proves: that a holder of an approved device signing key signed a specific
    sensor reading, and that the reading falls inside the numeric envelope its declared
    tier allows. That is all. It does NOT prove the reading describes reality — see
    SESSION.md §2 item 2. A device that lies inside its envelope produces a perfectly
    valid CONFIRMED proof.

    The three verdicts fall out of the shape rather than being asserted:

      verdict = 1 (CONFIRMED)  a valid signature over an in-envelope reading
      verdict = 0 (REFUTED)    a valid signature over an out-of-envelope reading
      no proof at all           UNRESOLVED — nobody claimed anything provable

    `verdict` is constrained to equal the envelope check on the private witness, so a
    prover cannot relabel its own reading. REFUTED is therefore a *proof* that a signed
    reading breaks its tier's rules, not merely the absence of a proof.

    `deviceKeyHash` is public and is what `CircomVerifier` checks against its registry of
    approved devices. That binding has to be constrained here or the whole gate is
    theatre: the circuit takes the public key as a private witness input, so without
    `keyHash === Poseidon(Ax, Ay)` a prover could sign with a key they made up, then
    *claim* an approved deviceKeyHash. The pairing would pass, the registry would pass,
    and anyone could close the gate on anyone else's evidence. Binding the hash to the
    actual public key inside the circuit is what makes `approveDevice` the trust
    boundary rather than a suggestion.
*/

template Envelope() {
    // Per-tier envelope: tier t accepts readings in [0, hi[t]]. Index 0 is UNVERIFIED,
    // deliberately the narrowest — a claim that has declared no confidence has to clear
    // the strictest bar and cannot reach a wide tier-5 window by relabelling itself.
    // Tier 6 (R5) accepts any reading expressible in 33 bits.
    var TIER_HI[7] = [100, 100, 1000, 10000, 100000, 1000000, 4294967295];

    // public — the four values `CircomVerifier` checks the proof against.
    signal input contentHash;
    signal input tier;
    signal input verdict;
    signal input deviceKeyHash;

    // private — the signed reading and the signature.
    signal input deviceId;
    signal input reading;
    signal input timestamp;
    signal input Ax;
    signal input Ay;
    signal input S;
    signal input R8x;
    signal input R8y;

    var i;

    // --- tier names a real envelope -------------------------------------------------
    // TIER_HI is only populated for 0..6, so an out-of-range tier has to be rejected
    // here rather than quietly reading a zero bound.
    component tierValid = LessThan(8);
    tierValid.in[0] <== tier;
    tierValid.in[1] <== 7;
    tierValid.out === 1;

    // --- envelope lookup ------------------------------------------------------------
    // `tier` is public and now known to be in 0..6, so exactly one selector is 1.
    // `IsEqual` rather than `tier == i`: the `==` operator yields a boolean and cannot be
    // multiplied, so the selector has to be a signal.
    component eq[7];
    signal sel[7];
    signal contrib[7];
    for (i = 0; i < 7; i++) {
        eq[i] = IsEqual();
        eq[i].in[0] <== tier;
        eq[i].in[1] <== i;
        sel[i] <== eq[i].out;
        contrib[i] <== TIER_HI[i] * sel[i];
    }

    signal hi;
    hi <== contrib[0] + contrib[1] + contrib[2] + contrib[3] + contrib[4] + contrib[5] + contrib[6];

    // --- verdict is the envelope check, not a claim ----------------------------------
    // This is the load-bearing constraint. `verdict` is not a label the prover picks: it
    // is pinned to whether `reading` cleared `hi`. `reading` is held below 2^32 and `hi`
    // is at most 2^32-1, so a 33-bit comparison with no wraparound.
    component readingBits = Num2Bits(33);
    readingBits.in <== reading;
    readingBits.out[32] === 0;

    component inEnvelope = LessEqThan(33);
    inEnvelope.in[0] <== reading;
    inEnvelope.in[1] <== hi;

    verdict === inEnvelope.out;

    // --- the claimed device key IS the signing key ------------------------------------
    component keyHash = Poseidon(2);
    keyHash.inputs[0] <== Ax;
    keyHash.inputs[1] <== Ay;
    deviceKeyHash === keyHash.out;

    // --- the signature covers every field ---------------------------------------------
    // M is the message. Everything that defines the claim goes in, so a proof cannot be
    // lifted onto a different attestation, a different reading, or a different tier.
    component msg = Poseidon(5);
    msg.inputs[0] <== deviceId;
    msg.inputs[1] <== reading;
    msg.inputs[2] <== timestamp;
    msg.inputs[3] <== contentHash;
    msg.inputs[4] <== tier;

    component sig = EdDSAPoseidonVerifier();
    sig.enabled <== 1;
    sig.Ax <== Ax;
    sig.Ay <== Ay;
    sig.S <== S;
    sig.R8x <== R8x;
    sig.R8y <== R8y;
    sig.M <== msg.out;

    // --- a reading was actually taken -------------------------------------------------
    // Zero is the shape a lazily-filled record takes; reject it so the envelope check
    // never passes on a reading that was never measured.
    component tsNonZero = IsZero();
    tsNonZero.in <== timestamp;
    tsNonZero.out === 0;
}

component main {public [contentHash, tier, verdict, deviceKeyHash]} = Envelope();