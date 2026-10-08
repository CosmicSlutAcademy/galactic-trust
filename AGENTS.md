# AGENTS.md — Galactic Trust (GLT)

Foundry 1.5.1 / Solidity 0.8.33 / OpenZeppelin 5.7.0. Single contract, escrow-heavy, un-audited.

**Read `SESSION.md` before changing anything.** It is 775 lines and is the real source of
truth: §2 design decisions that must not be relitigated, §4 the contract surface, §5 every
fund-loss bug this project has already shipped and fixed, §6 the ordered next actions.
§5 in particular is the map to hand an auditor.

## Commands

```bash
cd ~/galactic-trust
/home/alexa/.foundry/bin/forge test                        # 156/156, ~8 s
FOUNDRY_PROFILE=deep /home/alexa/.foundry/bin/forge test   # ~160 s, pre-ship
/home/alexa/.foundry/bin/forge build --sizes               # MUST stay under 24,576 B
```

Use the **absolute path**. `/usr/bin/forge` is ZOE, an unrelated 2013 estimation tool that
shadows the real binary on non-interactive shells. `SESSION.md` §3 says PATH is configured;
§5 says the fix only covers interactive and login shells, so a script invoked as
`bash foo.sh` still resolves ZOE. The absolute path works either way. Symptom:
`ZOE ERROR ... zoeParseOptions: unknown option`, or seven consecutive `BUILD FAILED` lines
that were never build failures.

Current size: 23,020 B, **1,556 B of margin**. Roughly one and a half small features. Run
`--sizes` on every change and report the delta.

`CircomVerifier` is a **separate contract** (3,573 B). Anything implementing `IVerifier`
should be too — that is how the proof system was added at zero cost to the token's margin.

## What this contract is

An ERC-20 whose supply is released by a staked, bonded, disputable attestation process.

> GLT asserts that these weighted parties staked these amounts on this claim, and that this is
> the dispute record. **It does not assert that the claim is true.**

Do not "improve" the design by adding truth-adjacent semantics. The oracle problem is unsolved
here, not avoided: trust is bounded and slashable, not eliminated. Three original pillars were
impossible as written (LoRaWAN settlement, ZK-proves-truth, legal binding — §2), and the
substitutes chosen for each are deliberate.

Two rules that look wrong but are not:

- **A tri-state evidence gate.** `CONFIRMED` / `REFUTED` / `UNRESOLVED`, with a reverting
  verifier mapped to `UNRESOLVED`. A boolean collapses "the proof says false" and "the proof
  system is broken" into one value, and that is how an outage becomes a silent mint or a total
  freeze. `UNRESOLVED` is the failsafe. No verifier set means `CONFIRMED`.
- **No probabilistic judge on the mint path.** A contract cannot compute a probability, so
  the value gets flattened to a scalar and the uncertainty is destroyed at that point. An
  off-chain model may publish a hashed reasoning artifact for curators to read. It can trigger
  the bypass. It can never mint.

## The failure modes this codebase is most prone to

`SESSION.md` §5 is long for a reason. Five patterns account for nearly all of it:

1. **A per-record field not cleared where its twin is cleared.** `_penalise` clears
   `att.stake`; `finalizeAttestation` did not, and all 105 tests passed. Aggregate solvency
   read the already-correct `totalStaked`, so no invariant saw it. When adding a settlement
   path, diff it against every existing one and check the *record*, not just the arithmetic.

2. **A per-participant record cleared at settlement while its aggregate is not.** Clearing
   `curatorBallot[id][c]` let a curator stack a second vote onto a decided tally, because
   `upholdWeight` / `rejectWeight` are never reset. Any slot cleared at settlement must be
   checked against the aggregates it fed.

3. **A bond withdrawable before the slash.** A bond is only real if bond → rule → deactivate
   → withdraw is closed. `curatorOpenVotes` and `lockedChallengeBond` exist for this.

4. **Live reads where a snapshot was required.** Quorum is snapshotted at submission for both
   attesters and curators. Reading it live let the owner appoint a whale mid-dispute and freeze
   the dispute permanently.

5. **A vacuous property.** Two of the properties written to catch the 2026-10-05 bugs were
   green while testing nothing. A property the code already enforces cannot fail; a
   precondition reading a different source of truth is silently false; a precondition on a
   1-in-16 hash bucket is silent 15 times out of 16.
   **To confirm a property is real, break the code it describes and check it goes red.**

6. **A property of a circuit, checked only from the contract.** Some claims about a ZK proof
   system cannot be seen from Solidity at all. "The verdict is pinned to the envelope check"
   is not testable on-chain — there, the verdict is simply part of the proof's public signals,
   so a mismatch fails the pairing for an unrelated reason and the test stays green either way.
   To check it: remove the constraint, rebuild circuit and keys, and ask the *prover* to claim
   the wrong verdict. The witness is accepted with the constraint gone, rejected with it in
   place. Same for binding `deviceKeyHash` to the signing key: remove
   `deviceKeyHash === Poseidon(Ax, Ay)` and the unapproved device's proof verifies.

   Also: read the invariant handler's revert column, not the suite result.
   `reverts ≈ calls` means the operation is failing on every invocation while the suite stays
   green. That is exactly how `configureVerifier` "passed" for a session — 440 reverts out of
   440 calls.

## Conventions

- Custom errors, not `require` strings. Watch for name collisions between an error and an
  event: `AttestationChallenged` existed as both, and renaming the event moved the caret
  without fixing anything. Check the *declaration*.
- `vm.expectRevert(bytes4)` requires exact revert data in this version. Use
  `abi.encodeWithSelector(...)` or `vm.expectPartialRevert(...)`.
- Enum comparisons in `assertEq` need casts on both sides.
- `200 + type(uint128).max` evaluates in uint128 and overflows. Write
  `uint256(type(uint128).max) + 200`.
- Tests: `_assertSolvent()` in every new test, asserting
  `balanceOf(address(this)) >= totalLiabilities()`. The invariant is **held ≥ owed**, not
  "the arithmetic balances".
- Tests needing two live attestations must use distinct secrets. The id is
  `keccak256(submitter, contentHash, timestamp, secret)` and Foundry does not advance
  `block.timestamp` between calls, so the same secret silently returns the same id and the
  second submission overwrites the first.
- Tests spanning two disputes need fresh participants for the second. After an uphold,
  attester1's bond is gone and challenger1's bond is forfeited, so reuse reverts on *their*
  bond rather than on the thing under test.
- A challenge window is absolute. Warping forward to settle one dispute closes the filing
  period for every attestation submitted alongside it. File all challenges before any warp.
- Invariant handlers: no call may revert (wrap every external call in `try/catch`), and all
  handler state must be `internal` or the fuzzer calls the generated getters.
- Line numbers in `SESSION.md` §4 drift. Re-derive with
  `grep -nE "^\s+(function|constructor)" src/GalacticTrust.sol`.
- No test-only mint helpers. An unguarded `_mint` in a token contract is a backdoor. Initial
  supply is a constructor argument.
- Do not gate payouts on a transient array. `_penalise` clears the challenger list, so
  `wasChallenger` and `payoutShare[id][addr]` must persist past settlement.

## Boundaries

- **Do not spend EIP-170 margin casually.** It is a hard cliff that makes the contract
  undeployable, and gas is a soft recurring cost. When they conflict, margin wins. Current
  margin is 1,556 B; `optimizer_runs` 20 → 1 buys 47 B for ~1.6% gas if needed.
- **Do not add a probabilistic signal to the mint path.** See the design rules above.
- **Do not reintroduce single-challenger escalation.** Challenges accumulate; escalation is a
  curator-quorum event. `test_ChallengeDoesNotFreezeSignatures` guards this.
- **Do not regress per-attester slashing.** The attesters who certified a lie must lose their
  bond, not just the submitter. This was the largest correctness gap in the original design.
- **Do not add a testnet or mainnet deploy.** `SESSION.md` §6: the only engineering item that
  gates shipping is an external audit, and it is not optional.
- **Ask before touching `_penalise`, `_resolve`, or `_settleCurators`.** These are where the
  fund-loss bugs live.
- Do not commit `lib/`, `out/`, `cache/`, `broadcast/`, or `.env*`. Already ignored.

## Testing posture

The adversarial and fuzz suites are **not** redundant with the unit suite. Every real bug
found in the 2026-09-30 audit was invisible to the unit suite and visible to one of the other
two.

Before shipping any change to settlement code:

```bash
/home/alexa/.foundry/bin/forge test --match-path test/Invariant.t.sol   # read the revert column
/home/alexa/.foundry/bin/forge test --match-test testFuzz --fuzz-runs 2000
FOUNDRY_PROFILE=deep /home/alexa/.foundry/bin/forge test
/home/alexa/.foundry/bin/forge build --sizes
```

Write adversarial tests first: two challengers, a hostile owner, an exit mid-dispute. A green
suite means the happy path works, nothing more.

## Layout

```
src/GalacticTrust.sol     the token, attestation lifecycle, escrow accounting (965 lines)
src/IVerifier.sol         tri-state gate: CONFIRMED / REFUTED / UNRESOLVED
src/CircomVerifier.sol    IVerifier over Groth16 + a governed device registry
circuit/evidence.circom   proves: approved device signed an in-envelope reading
circuit/build.sh          circuit -> keys -> Verifier.sol (re-running it invalidates proofs)
script/vacuity-check.sh     reverts each fix in turn; every new property must go red
circuit/genproofs.js      regenerates test/fixtures/proofs.json (real signatures + proofs)
test/GalacticTrust.t.sol  83 unit tests, lifecycle + governance
test/Adversarial.t.sol    33 tests: hostile owner, broken verifier, ties, no-challenger
test/CircomVerifier.t.sol 25 tests against real Groth16 proofs
test/Fuzz.t.sol            5 fuzz suites: conservation + terminality
test/Invariant.t.sol      10 stateful invariants over a 17-operation handler
script/Deploy.s.sol       Deploy + read-only Verify
SESSION.md                working log, including everything that has already gone wrong
```

## Deploy notes

`registerCurator` / `registerAttester` are `onlyOwner` and the owner is the
`TimelockController`, so they **cannot** be called by the deployer. There is no inline path;
schedule through the timelock, then have each curator call `fundCuratorBond()` themselves.
The panel is dead until they do, and **it fails silently** — every parameter looks healthy.
Check with `script/Deploy.s.sol:Verify`, which is read-only and lives in a separate contract
from `Deploy` on purpose.