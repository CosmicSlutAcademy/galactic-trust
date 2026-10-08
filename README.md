# Galactic Trust (GLT)

An ERC-20 token whose supply is released by a **staked, bonded, disputable attestation
process** rather than by a schedule.

Someone locks GLT as stake, a weighted committee of attesters co-signs a claim, anyone may
challenge it with their own bond at stake, and a bonded curator panel settles any dispute.
Every role can lose its deposit. A claim that survives all of it mints the reward.

**GLT does not know whether your intelligence is true. It cannot.** Read the section below
before anything else.

## What this token does not do

> **GLT asserts that these weighted parties staked these amounts on this claim, and that this
> is the dispute record. It does not assert that the claim is true.**

There is no oracle here. A Solidity contract cannot determine whether a report describes
reality, so it does not try. What it does is bind the *signer* to the claim: the committee
member who certified it can be slashed for it.

That distinction is the whole design. The binding is to the staking party, not to reality,
which is what makes the token defensible even when the underlying consensus is worthless —
anyone can mint a counterfeit of a true thing, but not a counterfeit of a *stake*.

Two consequences worth stating plainly:

- **Tier and quorum mean "how much skin was on this", never "how true".** Downstream
  consumers decide for themselves where on their own spectrum to put the evidence.
- **Trust is bounded and slashable, not eliminated.** The oracle problem is unsolved here,
  not avoided. A colluding committee can certify a lie — and then every one of them loses
  their bond for it, which is the difference between this design and a trust-me scheme.

## Status

**Unaudited. Not deployed. Not ready to hold value.**

- No external audit has been done. This is the single biggest gap.
- There is now a real verifier. `circuit/evidence.circom` + `src/CircomVerifier.sol` implement
  `IVerifier` against a Groth16 proof system, exercised by 25 tests running real proofs. It is
  **not** set on any deployment — `verifier` is still `address(0)` unless you pass `VERIFIER`
  to the deploy script — so in a default deployment every verdict is still `CONFIRMED`.
- What a `CONFIRMED` means is narrow: an *approved device key* signed a reading that fits its
  declared tier's numeric envelope. It does not mean the reading is true. See below.
- The repository is at `~/galactic-trust`, built with Foundry 1.5.1, Solidity 0.8.33,
  OpenZeppelin 5.7.0. 150 tests pass, including 10 stateful invariants over a 17-operation
  handler.

The three pillars of the original design could not be built as written, and the reasons are
worth recording so they are not relitigated:

1. **Off-grid LoRaWAN settlement is physically impossible.** LoRaWAN is ~0.3–50 kbps; a chain
   node cannot sync consensus state over it, and if the internet is down the global ledger
   does not exist. Store-and-forward gives *eventual* settlement under partition, which is
   salvageable; continuous operation is not.
2. **ZK proves computation, not truth.** A proof can show a report is well-formed. It cannot
   show an institution did what the report claims. The built verifier proves exactly that
   much and no more: a registered device signed a sensor reading, and that reading is inside
   the numeric envelope its declared tier allows. A device that lies *within* its envelope
   gets a valid `CONFIRMED`. Commit-reveal (`contentHash` + `secret`, revealed during
   disputes) still carries the confidentiality, and the bonded curator panel still carries the
   judgement.
3. **Smart contracts are not legally binding.** No jurisdiction enforces Solidity. Real
   enforcement needs a legal wrapper and human arbitration, neither of which exists here.

## How an attestation works

```
submitAttestation()    lock stake, open a 2-day challenge window
  ├─ signAttestation()       attesters co-sign, weight accumulates   (bond required)
  ├─ challengeAttestation()  anyone may challenge, bond locked       (bond required)
  └─ castCuratorVote()       bonded curators rule, weight accumulates (bond required)
       │
       ├─ CONFIRMED + quorum + no challenges → finalize, stake returned, reward minted
       ├─ REFUTED or UNRESOLVED            → forced to the panel (needs no challenger)
       └─ panel reaches quorum, no tie    → tallyDispute:
              uphold → submitter's stake burned, every signing attester's bond burned,
                      forfeited challenge bonds escrowed and pulled by each challenger
              reject → challengers' bonds burned, back to PENDING, can finalize
       └─ panel stalls (tie, or quorum unreachable) → expireReview after 7 more days:
              rejects by default, so a deadlocked panel can never slash an innocent submitter
```

### The evidence gate is three-state, not a boolean

A boolean collapses *"the proof says this is false"* and *"the proof system is broken"* into
one value. Treating those alike is exactly how a verifier outage becomes either a silent mint
or a total freeze. So the verdict is tri-state:

| Verdict | Effect |
|---|---|
| `CONFIRMED` | finalizes on the normal quorum path |
| `REFUTED` | cannot finalize; forced to a curator panel |
| `UNRESOLVED` | cannot finalize; forced to a curator panel. **This is the failsafe.** |
| no verifier set | `CONFIRMED` — absence of an opinion is not an objection |

The contract calls the verifier inside a `try/catch` and maps a **revert** to `UNRESOLVED`, so
a broken proof system can never halt the protocol. Fail-closed was rejected as the base case
because it makes `setVerifier` a single point of total failure with no override; this shape
gets the teeth without the liveness dependency.

### The verifier: what a verdict actually certifies

`circuit/evidence.circom` proves one thing — that a holder of an **approved device signing
key** signed a specific sensor reading, and that the reading sits inside the numeric envelope
its declared tier allows (tier 0 / `UNVERIFIED` accepts 0–100; tier 3 / `R2` accepts 0–10000;
tier 6 / `R5` accepts anything under 2³²). `src/CircomVerifier.sol` checks the Groth16 pairing,
records the outcome, and answers `IVerifier`.

| State | Meaning |
|---|---|
| `CONFIRMED` | an approved device signed a reading that fits its tier's rules |
| `REFUTED` | an approved device signed a reading that breaks them |
| `UNRESOLVED` | no approved device has proved anything about this evidence |

Three properties are worth stating plainly, because they are easy to over-claim:

- **This is not a truth claim.** A device that reports a plausible-but-false number inside its
  envelope produces a valid `CONFIRMED`. The gate catches *out-of-spec* evidence; it does not
  upgrade "well-formed" into "correct". §2 item 2 above is the reason this is the design.
- **The device registry is the trust boundary, not the proof.** The circuit proves *a*
  signature; it cannot prove *whose*. Without `approvedDevice`, anyone could mint a valid
  `REFUTED` for anyone else's evidence and close the gate at will. The circuit also pins
  `deviceKeyHash === Poseidon(Ax, Ay)`, so the key claimed in the public signals is the key that
  actually signed — otherwise a prover would sign with a key of their own and assert an
  approved hash.
- **`REFUTED` is a proof, not an absence.** The verdict is constrained in-circuit to the
  envelope check on the private witness, so `REFUTED` means "this signed reading breaks the
  rules", and a prover cannot relabel its own reading. Removal of that single constraint is what
  `test_CannotRelabelAProofAsRefutedWhenItIsInEnvelope` guards.

`verifyEvidence` is `view` per `IVerifier`, so it cannot take a proof as an argument and cannot
afford a ~300k-gas pairing on every read. The pairing runs once in `submitProof` (permissionless,
first write wins) and only the verdict is persisted. **An evidence hash above the BN254 field
prime is refused, not reduced** — `hash` and `hash - SNARK_FIELD` share a field element, so
reducing would let one attestation read another's verdict. That is a real constraint: about 81%
of uniformly random bytes32 values, `keccak256` output included, are out of field. Nothing is
lost (the verdict stays `UNRESOLVED`, which routes to the panel), but check `isProvable(hash)`
before choosing one, or a claim meant to be machine-checkable silently never becomes so.

Deliberately: **no probabilistic judge touches the mint path.** An earlier proposal was for an
off-chain model to score "existence probability" and have the contract act on it. A contract
cannot compute a probability, so the value must be flattened to a scalar somewhere, and the
uncertainty that motivated it is destroyed at exactly that point. Worse, an evidence gate that
admits *high-probability* claims is by definition a gate that mints rewards for things known to
be possibly false — the precise failure this contract exists to prevent. If a model is ever
used it publishes a hashed reasoning artifact that curators read before voting. It can trigger
the bypass; it can never mint.

## Properties the tests actually pin

Each of these exists because its absence was a bug that a green suite walked past.

- **The contract is provably solvent.** `totalLiabilities()` sums every stake, payout escrow
  and bond pool; every token movement updates it, and `recoverExcessStake` can only burn the
  unbacked remainder. The invariant is not "the arithmetic balances", it is **held ≥ owed**.
- **A wrong book is as bad as a wrong balance.** One bug left `balanceOf` exactly right and
  `totalStaked` wrong; another left settlement correct and the public record claiming a
  finalized attestation still held stake. `held ≥ owed` alone walks straight past both, so
  there are invariants over the per-record state too.
- **A bond that can be withdrawn before the slash is not a bond.** `curatorOpenVotes` counts
  unsettled ballots and blocks withdrawal, closing bond → rule → deactivate → withdraw.
- **A ruling that can be revisited is not a ruling.** Curator ballots are permanent *and* the
  panel refuses to re-open once it has ruled. The first half alone left other curators free to
  add weight to a tally that had already been applied.
- **Silence is not acquittal, and a tie is not acquittal either.** `panelOverride` — which
  lets a panel overrule a `REFUTED`/`UNRESOLVED` verdict and make the attestation finalizable —
  requires a strict reject majority. An unattended expiry used to set it, which meant submitting
  against refuted evidence, waiting out the review window, and minting.
- **A stalled dispute always terminates.** Every terminal branch is reachable within
  `CHALLENGE_WINDOW + REVIEW_WINDOW`. The owner cannot freeze an in-flight dispute.
- **Quorum is snapshotted at submission**, for both attesters and curators. Reading curator
  quorum live at tally time let the owner appoint a whale mid-dispute and push the bar above
  reachable weight, freezing the dispute with funds locked — verified to last forever.
- **Settlement cost is bounded.** `MAX_SIGNERS` / `MAX_CHALLENGERS` / `MAX_CURATORS` cap the
  loops; challenger payouts are pull-based so a large challenger set cannot make settlement
  unspendable.
- **A single challenger cannot freeze anything.** Challenges accumulate; escalation is a
  curator-quorum event, not one wallet's decision.
- **The bytecode fits.** 23,020 B against the 24,576 B EIP-170 limit — 1,556 B of margin. The
  optimizer was silently off at one point, leaving 38 KB of undeployable bytecode that a
  fully passing test suite was perfectly happy with. `forge build --sizes` is part of the build
  for that reason. The verifier is a **separate contract** (3,573 B), so adding a real proof
  system cost the token nothing.
- **A verdict cannot be relabelled, and cannot be claimed by the wrong key.** Both are
  properties of the circuit, so they are verified by breaking the circuit and confirming the
  tests go red — not by reading the constraint and nodding. Both were confirmed to go red.

## Running it

```bash
cd ~/galactic-trust
/home/alexa/.foundry/bin/forge test                        # 156/156, ~8 s
FOUNDRY_PROFILE=deep /home/alexa/.foundry/bin/forge test   # 5 fuzz at 2000 runs + 10 invariants at 128,000 calls each, ~160 s
/home/alexa/.foundry/bin/forge build --sizes               # MUST stay under 24,576 B
```

### Rebuilding the circuit

Only needed when `circuit/evidence.circom` changes. **Regenerating the keys invalidates every
proof already submitted on chain**, which is why `circuit_final.zkey`, `verification_key.json`
and `circuit/Verifier.sol` are committed.

```bash
bash circuit/build.sh                          # compile + trusted setup + export Verifier.sol
cd ~/.localtools/snarkjs && node ~/galactic-trust/circuit/genproofs.js   # regenerate the test fixtures
```

The toolchain lives outside the repo (`~/.local/bin/circom`, `~/.localtools/snarkjs`) because
`npm` on this box resolves to the Windows binary via `/mnt/c`. The test fixtures are committed
rather than generated during `forge test`: proving takes ~15 s per proof, and the point of the
suite is to run on every edit.

`snarkjs`'s `exportSolidityCallData` is the only correct source for the on-chain proof encoding.
`proof.pi_b` is *not* the layout the generated Solidity verifier wants — each G2 row has its
coordinates flipped — and copying it verbatim yields a proof that `groth16.verify` accepts and
the EVM rejects. `genproofs.js` asserts the flip happened rather than assuming it.

Two profiles, and the split is deliberate: the default is fast enough to run on every edit,
`deep` is what CI and any pre-ship run must use. An invariant suite nobody runs is the same as
no suite, so the fast default is the honest one.

`forge test --match-path test/Invariant.t.sol` also prints a per-operation
`Calls / Reverts / Discards` table. Read it, not just the PASS line: an operation whose
revert count matches its call count is failing silently on every invocation while the suite
stays green. That is how `configureVerifier` once "passed" for a whole session.

⚠️ Call `/home/alexa/.foundry/bin/forge` by absolute path, always. `/usr/bin/forge` is *ZOE*,
an unrelated 2013 estimation tool, and it shadows the real binary. Bare `forge` works
interactively and from a login shell, so this looks fine right up until it is run from a
script: `env -i /bin/sh script.sh` resolves ZOE. Symptom: `ZOE ERROR ...
zoeParseOptions: unknown option` — and on a build probe it comes back as seven consecutive
`BUILD FAILED` lines that were never build failures.

### Layout

```
src/GalacticTrust.sol         the token, the attestation lifecycle, and the escrow accounting
src/IVerifier.sol             tri-state evidence gate: CONFIRMED / REFUTED / UNRESOLVED
src/CircomVerifier.sol        IVerifier over Groth16 + a governed device registry
circuit/evidence.circom       proves: approved device signed an in-envelope reading
circuit/build.sh              circuit -> keys -> Verifier.sol
circuit/genproofs.js          regenerates the test fixtures (real signatures, real proofs)
test/GalacticTrust.t.sol      83 unit tests, lifecycle and governance
test/Adversarial.t.sol        27 tests: hostile owner, broken verifier, ties, no-challenger
test/CircomVerifier.t.sol     25 tests against real Groth16 proofs
test/Fuzz.t.sol               5 fuzz suites: conservation and terminality
test/Invariant.t.sol         10 stateful invariants over a 17-operation handler
test/fixtures/proofs.json    committed proofs (regenerating them takes minutes)
script/Deploy.s.sol          Deploy + read-only Verify
SESSION.md                    the working log, including what has already gone wrong here
```

`SESSION.md` §5 is a list of the bugs this project has already shipped and fixed. It is worth
reading before touching the settlement code — and it is the map to hand an auditor.

## Bringing a deployment up

The deploy script cannot appoint the committee. `registerCurator` and `registerAttester` are
`onlyOwner` and the owner is the `TimelockController`, so they must go through the timelock.

```bash
export PRIVATE_KEY=... TREASURY=... INITIAL_SUPPLY=...
forge script script/Deploy.s.sol:Deploy --rpc-url <url> --broadcast
```

Then, through the timelock:

1. `schedule` + `execute` `registerCurator(curatorN, weight)` for each panel member.
2. **Each curator calls `fundCuratorBond()`.** Until they do, the panel cannot rule on
   anything — every vote reverts `BondBelowRequired`. This is the step most likely to be
   missed and it fails silently: the deployment looks healthy.
3. `schedule` + `execute` `registerAttester(...)`, then each attester calls
   `fundAttesterBond()`.
4. Set a `verifier` if you have one. Without it every verdict is `CONFIRMED`.

Check the result rather than trusting the deploy:

```bash
GLT=<glt> TIMELOCK=<timelock> forge script script/Deploy.s.sol:Verify --rpc-url <url>
```

`Verify` asserts the owner really is the timelock, the delay is non-zero, no bond is zero, a
curator is actually bonded, and held covers owed. It is read-only and lives in a separate
contract from `Deploy` on purpose: a verification that can broadcast is a verification someone
will eventually broadcast by accident.

## Licence

MIT.