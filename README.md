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
- There is no real verifier. `IVerifier` is wired in, enforced at finalization, and returns
  one of three verdicts — but nothing implements it yet, so every verdict is `CONFIRMED` and
  the gate has never been exercised against a real proof system.
- The repository is at `~/galactic-trust`, built with Foundry 1.5.1, Solidity 0.8.33,
  OpenZeppelin 5.7.0. 125 tests pass, including 10 stateful invariants over a 17-operation
  handler.

The three pillars of the original design could not be built as written, and the reasons are
worth recording so they are not relitigated:

1. **Off-grid LoRaWAN settlement is physically impossible.** LoRaWAN is ~0.3–50 kbps; a chain
   node cannot sync consensus state over it, and if the internet is down the global ledger
   does not exist. Store-and-forward gives *eventual* settlement under partition, which is
   salvageable; continuous operation is not.
2. **ZK proves computation, not truth.** A proof can show a report is well-formed. It cannot
   show an institution did what the report claims. What is built instead is commit-reveal
   (`contentHash` + `secret`, revealed during disputes): confidentiality without a proof
   system. `IVerifier` is the plug-in point for a real verifier later.
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
- **The bytecode fits.** 22,819 B against the 24,576 B EIP-170 limit — 1,757 B of margin. The
  optimizer was silently off at one point, leaving 38 KB of undeployable bytecode that a
  fully passing test suite was perfectly happy with. `forge build --sizes` is part of the build
  for that reason.

## Running it

```bash
cd ~/galactic-trust
forge test                        # 125/125, ~5 s
FOUNDRY_PROFILE=deep forge test   # 5 fuzz suites at 2000 runs + 10 invariants at 128,000 calls each
forge build --sizes               # MUST stay under 24,576 B
```

Two profiles, and the split is deliberate: the default is fast enough to run on every edit,
`deep` is what CI and any pre-ship run must use. An invariant suite nobody runs is the same as
no suite, so the fast default is the honest one.

⚠️ Call `/home/alexa/.foundry/bin/forge` by absolute path inside any script. `/usr/bin/forge`
is *ZOE*, an unrelated 2013 estimation tool, and it shadows the real binary. Symptom:
`ZOE ERROR ... zoeParseOptions: unknown option` — and on a build probe it comes back as seven
consecutive `BUILD FAILED` lines that were never build failures.

### Layout

```
src/GalacticTrust.sol   the token, the attestation lifecycle, and the escrow accounting
src/IVerifier.sol       tri-state evidence gate: CONFIRMED / REFUTED / UNRESOLVED
test/GalacticTrust.t.sol   83 unit tests, lifecycle and governance
test/Adversarial.t.sol      27 tests: hostile owner, broken verifier, ties, no-challenger
test/Fuzz.t.sol              5 fuzz suites: conservation and terminality
test/Invariant.t.sol        10 stateful invariants over a 17-operation handler
script/Deploy.s.sol         Deploy + read-only Verify
SESSION.md                  the working log, including what has already gone wrong here
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