# SESSION STATE — Galactic-Trust (GLT) / GCIA epistemic ledger
> Re-read this file first every time you resume. This is the single source of truth for GLT.

**Last updated:** 2026-10-08
**Operator:** alexa @ Ubuntu 26.04.1 (WSL2)
**Location:** `~/galactic-trust` (1,159 src / 4,813 test lines Solidity + one circom circuit)
**Status:** 156/156 tests green on both profiles (default ~8 s; `deep` = 5 fuzz suites at
2000 runs + 10 invariants at 128,000 calls each = 187 s), deploy script exercised against
Anvil, a real Groth16 verifier built and tested against genuine proofs, NOT deployed to a
public network, NOT audited.

**Read this first if you are resuming.** The referral path was never tested until
2026-10-05, and finding out why produced three fund-loss bugs plus two properties that
passed while testing nothing at all. Both lessons are in §5; the short version is that a
green property is not evidence of anything until you have watched it fail.

**Second thing to read.** §6 item 2 (the circom verifier) was marked **blocked** on a missing
toolchain. It is no longer blocked, and it is now built. What it took is in §5 "The circom
toolchain lessons" — including one bug that made every valid proof read as rejected while
`groth16.verify` in JavaScript happily accepted the same proof.

---

## 1. Current status

| Item | State |
|---|---|
| Foundry toolchain | ✅ installed at `~/.foundry/bin` (forge 1.5.1) — **use the absolute path in scripts, see §3** |
| `GalacticTrust.sol` | ✅ compiles, quorum attestation + challenge window + slashing |
| Test suite | ✅ 156/156 passing (83 unit + 33 adversarial + 5 fuzz + 10 invariant + 25 verifier) |
| Tri-state evidence gate | ✅ `CONFIRMED`/`REFUTED`/`UNRESOLVED`, enforced at finalize |
| Verifier outage failsafe | ✅ a reverting verifier → `UNRESOLVED`, never a protocol halt |
| Curator quorum snapshot | ✅ snapshotted at submission, owner cannot move it mid-dispute |
| Dispute tie-break | ✅ `expireReview` after `REVIEW_WINDOW` (7 days), rejects by default |
| Commit-reveal gating | ✅ post-window, challenger-or-curator only, verify-and-emit |
| Fuzz suite | ✅ conservation + multi-challenger payout + expiry terminality + curator slash |
| **Invariant handler** | ✅ **10 stateful invariants, 17 handler ops — §6.3 closed, found 1 bug** |
| **Curator stake behind appointment** | ✅ **bonded, locked while voting, loser's bond slashed — §6.1 closed** |
| Escrow solvency invariant | ✅ `totalLiabilities()` accounted on every movement |
| Owner burn limited to unbacked balance | ✅ `recoverExcessStake` cannot touch live escrow |
| Challenge bond locked while challenge open | ✅ `lockedChallengeBond` |
| Contract size within EIP-170 | ✅ 23,020 B — 1,556 B margin |
| **Real ZK verifier** | ✅ **BUILT — `circuit/evidence.circom` + `src/CircomVerifier.sol`, Groth16, 25 tests on real proofs. NOT wired into any deployment** |
| **Verifier trust boundary** | ✅ **device registry; `deviceKeyHash` bound to the signing key in-circuit — see §5** |
| **Evidence-hash field check** | ⚠️ **`_inField` refuses out-of-field hashes. ~81% of random bytes32 are out of field — see §5** |
| **Referral path** (`REFUTED`/`UNRESOLVED` → panel → `panelOverride`) | ✅ **now exercised — 3 bugs found and fixed, see §5** |
| **Panel cannot be re-opened after ruling** | ✅ `panelSettled` — a ruling is final |
| **`panelOverride` requires a strict reject majority** | ✅ silence and ties no longer grant approval |
| Deactivation rejects unknown addresses | ✅ `NotAttester`/`NotCurator`, idempotent for real ones |
| Deploy script | ✅ **exercised end-to-end on Anvil — 2 bugs found, see §5** |
| Post-deploy verification | ✅ `Deploy.s.sol:Verify`, 8 read-only assertions |
| README | ✅ real front page, states plainly that GLT asserts *stakes*, never truth |
| Attester bonds + attester slashing | ✅ built and tested |
| Challenge bonds | ✅ built — required to challenge, forfeited if rejected |
| Weighted curator panel | ✅ built — `onlyOwner` ruling replaced |
| Bounded settlement loops | ✅ `MAX_SIGNERS`/`MAX_CHALLENGERS`/`MAX_CURATORS` caps + pull payments |
| Access-gating / query fees (pillar 2) | ❌ not built — separate contract |
| Audit | ❌ none |
| Git remote | ✅ `origin` → `CosmicSlutAcademy/galactic-trust`, **3 commits unpushed** |
| Mainnet/testnet deploy | ❌ none |

---

## 2. Design decisions (do not undo without reading this)

**Three pillars of the original spec could not be built as written.** Reasoning recorded so
it isn't relitigated every session:

1. **Off-grid LoRaWAN settlement is physically impossible.** LoRaWAN is ~0.3–50 kbps; a chain
   node cannot sync consensus state over it, and if the internet is down the global ledger does
   not exist. The salvageable version is *eventual* settlement under partition
   (store-and-forward), not continuous operation. **Not built yet.**

2. **ZK proves computation, not truth.** A ZK proof can show a report is well-formed; it cannot
   show an institution did what the report claims. Replaced with commit-reveal
   (`contentHash` + `secret`, revealed during disputes) which gives confidentiality without a
   proof system. `IVerifier` is the plug-in point for a real verifier later.

   **Resolution (2026-09-30): the gate is three-state, not boolean.** A bool collapses "the
   proof says false" and "the proof system is broken" into one value, and treating them alike
   is exactly how a verifier outage becomes either a silent mint or a total freeze.

   | Verdict | Effect |
   |---|---|
   | `CONFIRMED` | finalizes on the normal quorum path |
   | `REFUTED` | cannot finalize; forced to a curator panel; upheld → slash |
   | `UNRESOLVED` | cannot finalize; forced to a curator panel. **This is the failsafe.** |
   | no verifier set | `CONFIRMED` — absence of an opinion is not an objection |

   `_verdict()` wraps the verifier in try/catch and maps a **revert** to `UNRESOLVED`, so a
   broken proof system can never halt the protocol. Plain fail-closed was rejected as the base
   because it makes `setVerifier` a single point of total failure with no override; this shape
   gets the teeth without the liveness dependency.

   **No probabilistic judge touches the mint path, deliberately.** An earlier proposal was for
   an off-chain model to score "existence probability" and have the contract act on it.
   Rejected: a Solidity contract cannot compute a probability, so the value must be flattened to
   a scalar somewhere, and the uncertainty that motivated it is destroyed at exactly that
   point. Worse, an evidence gate that admits *high-probability* claims is by definition a gate
   that mints rewards for things known to be possibly false — the precise failure this contract
   exists to prevent. If a model is ever used it publishes a hashed reasoning artifact that
   curators read before voting. It can trigger the bypass; it can never mint.

   **What the coin does and does not claim.** GLT does not assert truth and must never be read
   as doing so. It asserts: *these N weighted parties staked X GLT on this claim, and here is
   the dispute record.* The binding is to the staking party, not to reality, which is what makes
   the token defensible when consensus is worthless — anyone can mint a counterfeit of a true
   thing, but not a counterfeit of a *stake*. Downstream consumers place the evidence on their
   own spectrum; tier and quorum mean "how much skin was on this", never "how true".

3. **Smart contracts are not legally binding.** No jurisdiction enforces Solidity. The real
   answer is a legal wrapper (Wyoming DAO LLC) + human arbitration for disputes. **Not done.**

**The oracle problem is unsolved, not avoided.** The contract cannot judge whether intel is
*correct*. It can only check that N weighted attesters signed. Trust is therefore bounded and
slashable, not eliminated. This is the honest version of the design.

---

## 3. Running it

```bash
cd ~/galactic-trust
/home/alexa/.foundry/bin/forge test                        # 125/125, ~6 s  (default profile)
FOUNDRY_PROFILE=deep /home/alexa/.foundry/bin/forge test   # 125/125, ~145 s (full sweep, pre-ship)
/home/alexa/.foundry/bin/forge build --sizes                # MUST stay under 24,576 B EIP-170
```

**Use the absolute path, not bare `forge`.** §5 records why, and it was re-verified
2026-10-06: `env -i /bin/sh script.sh` resolves `/usr/bin/forge`, which is ZOE. Bare `forge`
is safe interactively and from a login shell; it is *not* safe inside a script.

**Two profiles, and the split is deliberate.** The default runs invariants at 32×250 = 8,000
calls per property so `forge test` stays usable on every edit; `deep` runs 256×500 = 128,000
calls plus fuzz at 2,000. An invariant suite nobody runs is the same as no suite, so the fast
default is the honest one and `deep` is what CI and any pre-ship run must use.

**Read the invariant handler table, not just the suite result.** `forge test --match-path
test/Invariant.t.sol` prints `Calls / Reverts / Discards` per handler operation. Reverts ≈
calls means the operation is failing silently on every invocation while the suite passes — that
is what happened to `configureVerifier` for a whole session (§5). This is the one diagnostic
here that a green run actively hides from you.

⚠️ **`invariant_runs` / `invariant_depth` at the top level of `foundry.toml` are accepted
silently and ignored.** They must be in an `[invariant]` table as `runs` and `depth`. Verified
with `forge config | sed -n '/\[invariant\]/,/^$/p'`. Same trap for fuzz: `[fuzz] runs`.

**PATH is configured for interactive and login shells only** — `~/.bashrc:124` and
`~/.profile:32-33`. Verified 2026-10-06: `bash -lc 'command -v forge'` → the real binary, but
`env -i /bin/sh script.sh` → `/usr/bin/forge` (ZOE). **This is why the commands above use
the absolute path, and why "PATH is already configured, no export needed" was wrong as
written** — it was true for the shells it was tested in and false for scripts.

⚠️ **`/usr/bin/forge` is NOT Foundry.** It is *ZOE*, an unrelated estimation tool from 2013
(`ZOE library version 2013-02-16`), and it shadows the real binary. If `forge --version` prints
`ZOE ERROR ... unknown option`, the wrong one is resolving. The `.foundry/bin` entries are placed
*before* `/usr/bin` for exactly this reason. Verified: `bash -lc 'command -v forge'` →
`/home/alexa/.foundry/bin/forge`.

**Restoring dependencies on a fresh clone** (`lib/` is gitignored — 18 MB of vendored code
does not belong in git history):

```bash
forge install foundry-rs/forge-std
forge install OpenZeppelin/openzeppelin-contracts
```

Pinned versions this was built and tested against:

| Dependency | Version |
|---|---|
| foundry | 1.5.1-stable |
| optimizer | on, **20 runs** (was 200 — see §5 for the measured size/gas trade) |
| forge-std | 1.16.2 |
| openzeppelin-contracts | 5.7.0 |
| solc | 0.8.33 (auto-installed) |
| evm_version | prague |

**Deploy env vars** (read by `script/Deploy.s.sol`):
`PRIVATE_KEY`, `TREASURY`, `INITIAL_SUPPLY`, `TIMELOCK_DELAY`

---

### Test layout — read these before changing the settlement code

```
test/GalacticTrust.t.sol    83 unit tests, lifecycle + governance
test/Adversarial.t.sol      27 tests, hostile owner / broken verifier / tie / no-challenger
test/Fuzz.t.sol              5 fuzz suites, conservation + terminality + curator slash
test/Invariant.t.sol        10 stateful invariants over a 17-operation handler
```

The adversarial and fuzz files are not redundant with the unit suite. Every real bug found in
the 2026-09-30 audit was invisible to the unit suite and visible to one of the other two.
`forge test --match-test testFuzz --fuzz-runs 2000` before shipping any change to
`_penalise`, `_resolve`, or the liability counters.

⚠️ **Read the invariant suite's revert column, not just its PASS line.** `forge test
--match-path test/Invariant.t.sol` prints a per-handler `Calls / Reverts / Discards` table.
A handler operation with reverts ≈ calls is not running — it is failing silently on every
single invocation while the suite stays green. That is exactly how `configureVerifier`
"passed" for a whole session while reverting `OwnableUnauthorizedAccount` 440 times out of
440 (§5). It is the same failure shape as the 47-green-tests trap, one level down.

---

## 4. Architecture as built

### Lifecycle

```
registerAttester()   → fundAttesterBond()      (bond required before signing)
registerCurator()    → fundCuratorBond()       (bond required before ruling, cannot exit mid-vote)
submitAttestation()  → PENDING, stake locked in contract, 2-day window opens
  ├─ signAttestation()   ×N attesters, weight accumulates      (capped at MAX_SIGNERS)
  ├─ challengeAttestation() ×N challengers, accumulates       (bond required, capped)
  ├─ castCuratorVote()    ×N curators, weight accumulates      (bond required, capped,
  │                                                             dissenters lose bond)
  └─ after window closes:
       ├─ verdict CONFIRMED + quorum + zero challenges
       │      → finalizeAttestation() → stake returned + reward minted
       └─ anything else → curator panel (a REFUTED/UNRESOLVED verdict needs no challenger)
├─ quorum reached, non-tied → tallyDispute() → _resolve():
               │      every ruling first runs _settleCurators(), which slashes the bond of
               │      each curator who voted against the majority and frees their vote locks
               │      uphold → _penalise(): submitter stake burned (slashBps), every
               │                 signing attester's bond burned, pool = unburned remainder
               │                 + forfeited challenge bonds, each challenger PULLs its
               │                 own share via claimChallengeReward()
│      reject → _forfeitChallengeBonds() burns challengers' bonds, returns
       │                to PENDING, can finalize. Against a non-CONFIRMED verdict
       │                this sets panelOverride — the humans overruling the machine —
       │                but ONLY on a strict reject majority (rejectWeight > upholdWeight).
       │                Silence and ties do not qualify; see §5.
       │      either ruling sets panelSettled, so no further ballot is accepted.
       └─ stalled (tied, or quorum never reached)
              → after REVIEW_WINDOW: expireReview() → rejects by default.
                A REFUTED verdict is still punished: silence is not acquittal.
                Unless the panel actually voted to acquit, which spares the submitter.
```

> Every terminal branch is covered by `test/Adversarial.t.sol`, the conservation property by
> `test/Fuzz.t.sol`, and the referral routes by `test/Invariant.t.sol` — read those before
> changing anything in `_penalise`, `_resolve`, or `_settleCurators`.

### Key properties

- **Quorum is snapshotted at submission** (`att.quorumWeight`), so registering new attesters
  cannot retroactively change the bar for in-flight attestations.
- **Quorum is basis-points of total attester weight** (`quorumBps`, default 50%), not a fixed
  N. Scales from a 5-node testnet to a committee without a rewrite.
- **Challenges accumulate, they do not escalate.** This was a deliberate fix — see §5.
- **Challenges are bonded.** A challenger must hold `challengeBondAmount` to file. If curators
  reject the challenge the bond is burned, so frivolous challenging has a price.
- **Curators vote by weight; no single key decides.** A ruling needs curator quorum
  (`curatorQuorumWeight()`, also quorumBps) AND a non-tie. A split stalls rather than guessing.
- **A curatorship now costs skin.** `fundCuratorBond` locks GLT and `castCuratorVote` refuses a
  curator below `curatorBondAmount`, mirroring `signAttestation`'s gate on the attester bond.
  Without it the panel was the owner's key in a committee costume: weight was owner-assigned and
  free, so appointment was the whole of the trust model and the weighted panel only decentralised
  the ruling.
- **A curator who rules against the panel majority loses bond.** `_settleCurators` slashes every
  dissenter by `curatorSlashBps`, on both rulings. The majority is ground truth by construction,
  so a ballot opposing it is the only available signal for a bad ruling — the same reasoning as
  the attester leg in `_penalise`.
- **A curator cannot escape a slash by exiting.** `curatorOpenVotes` counts unsettled ballots and
  blocks `withdrawCuratorBond`, so bond → rule → deactivate → withdraw is closed. Deactivation is
  deliberately *not* sufficient: it is immediate and owner-reversible.
- **Curator quorum is snapshotted at submission too** (`att.curatorQuorumWeight`), matching
  the attester quorum. It was read live at tally time, so the owner could appoint a whale
  curator mid-dispute and push the bar above reachable weight — verified to freeze the
  dispute forever. Same class of bug, opposite side of the contract.
- **A stalled dispute now always terminates.** A tie or an unreachable quorum used to lock
  stake and bonds with no exit whatsoever (still reverting after 365 days). `expireReview`
  resolves it after `REVIEW_WINDOW`, defaulting to **reject** — an unreached or deadlocked
  panel can never slash a submitter who did nothing wrong. The one exception: an attestation
  whose evidence is `REFUTED` is still penalised on expiry, because silence is not acquittal.
- **The machine can be overruled, but only visibly.** Rejecting a dispute against a
  non-`CONFIRMED` verdict sets `panelOverride`, which is what makes such an attestation
  finalizable at all. Without it the attestation would deadlock permanently: verdict blocks
  finalization, the challenge window is closed, and the curators have all voted.
  **A strict reject majority is now required** (`rejectWeight > upholdWeight`). Previously any
  rejection set it, including the default-reject an unattended `expireReview` performs, so
  silence and ties were recorded as human approval. See §5.
- **A ruling is final.** `panelSettled[id]` refuses any further ballot once the panel has
  ruled. Making each curator's own ballot permanent was not enough on its own — other curators
  could still add weight afterwards. See §5.
- **Attesters must bond to sign, and cannot withdraw while active.** Prevents bond → certify
  → withdraw before a dispute resolves.
- **Attesters who sign a fabrication lose their bond.** This closes the colluding-quorum hole:
  previously a quorum could certify a lie, the submitter was punished, and the signers were free.
- **Settlement cost is bounded.** `MAX_SIGNERS` / `MAX_CHALLENGERS` (50 each) cap the loops;
  challenger payouts are pull-based so a large challenger set cannot make settlement
  unspendable. `_penalise` remains O(signers).
- **The contract is provably solvent.** `totalLiabilities()` sums stakes, payout escrow, and
  both bond pools; every token movement updates it, and `recoverExcessStake` refuses to burn
  above `excessBalance()`. `_assertSolvent()` in the test suite asserts
  `balanceOf(address(this)) >= totalLiabilities()` in every new test.
- Owner is expected to be a `TimelockController` with `admin = address(0)`.
- `Ownable2Step` — `transferOwnership` alone leaves one key in control until accepted.

### Contract surface (`src/GalacticTrust.sol`, 939 lines)

| Function | Line | Role |
|---|---|---|
| `fundAttesterBond` | 293 | lock GLT as signing bond |
| `withdrawAttesterBond` | 304 | reclaim bond, only after deactivation |
| `registerCurator` / `deactivateCurator` | 316 / 337 | panel appointment; deactivate reverts on unknown |
| `setCuratorBondAmount` / `setCuratorSlashBps` | 356 / 361 | curator bond + dissent penalty |
| `fundCuratorBond` | 367 | lock GLT as a curatorship bond |
| `withdrawCuratorBond` | 380 | reclaim, blocked while any vote is unsettled |
| `fundChallengeBond` | 393 | lock GLT as challenging bond |
| `withdrawChallengeBond` | 411 | reclaim only the *unlocked* portion |
| `registerAttester` / `deactivateAttester` | 419 / 438 | committee management; deactivate reverts on unknown |
| `submitAttestation` | 471 | lock stake, open window, returns `id` |
| `signAttestation` | 501 | attester co-sign, accumulates weight |
| `finalizeAttestation` | 521 | **the mint gate** — quorum + window + zero challenges |
| `challengeAttestation` | 573 | red-team flag, accumulates, locks bond |
| `castCuratorVote` | 593 | weighted panel ruling, bond-gated, refuses after settlement |
| `tallyDispute` | 624 | applies the ruling once curator quorum is met |
| `expireReview` | 648 | forces a stalled dispute after `REVIEW_WINDOW` |
| `claimChallengeReward` | 856 | per-challenger pull payment |
| `checkSecret` | 873 | stateless read-only hash check, records nothing |
| `revealSecret` | 886 | post-window, challenger/curator only, verify-and-emit |
| `evidenceVerdict` | 912 | the machine's tri-state opinion, never reverts |
| `totalLiabilities` | 917 | every token the contract owes, never burnable |
| `excessBalance` | 926 | held minus owed — the only burnable amount |
| `recoverExcessStake` | 934 | burns unbacked balance only |

Internal: `_resolve` (676) applies a ruling and owns both `panelOverride` rules,
`_settleCurators` (762) slashes dissenting curators, releases vote locks and sets
`panelSettled`, `_penalise` (791) burns the submitter stake and signing attesters.

Setters: `setVerifier`, `setQuorumBps`, `setMinStake`, `setRewardAmount`, `setSlashBps`,
`setAttesterBondAmount`, `setAttesterSlashBps`, `setChallengeBondAmount`, `setCuratorBondAmount`,
`setCuratorSlashBps` (all `onlyOwner`; both bond setters reject zero).
Getters: `challengeCount`, `signerWeight`, `attesterBond`, `challengeBond`, `curatorBond`,
`lockedChallengeBond`, `curatorOpenVotes`, `curatorBallot`, `panelSettled`, `payoutShare`,
`requiredQuorumWeight`, `getAttestation`, `attester`, `curator`.

> **`panelSettled` is new (2026-10-05).** Read it alongside `panelOverride`: the first says the
> panel has ruled and no further ballot is accepted, the second says the panel overruled a
> non-CONFIRMED verdict. They are independent, and §5 records why only having the first is not
> enough.

> Bond defaults, all non-zero on purpose: `attesterBondAmount` 100e18, `challengeBondAmount`
> 100e18, `curatorBondAmount` **1,000e18** (the panel is load-bearing for every REFUTED and
> UNRESOLVED verdict). `curatorSlashBps` and `attesterSlashBps` both default to 10,000.

> Line numbers drift. Re-derive with
> `grep -nE "^\s+(function|constructor)" src/GalacticTrust.sol` rather than trusting this table.

---

## 5. Hard-won lessons / gotchas

### The vacuous-property lessons (2026-10-05)

Three bugs found in one session by the invariant fixture, and the more useful finding was
that **two of the properties I wrote to catch them were passing while testing nothing.** Both
are recorded because the failure is silent and the suite is green throughout.

- **A property the code under test already enforces cannot fail.** My first override property
  was "an attestation finalized against a non-`CONFIRMED` verdict implies `panelOverride`".
  But `finalizeAttestation` gates on exactly that condition, so no such finalization can ever
  be recorded, so the implication is trivially true. I deleted the `panelOverride = true` line
  from `_resolve` and the property stayed green. The falsifiable form is the converse:
  "**`panelOverride` implies `rejectWeight > upholdWeight`**", which says the flag means what
  it claims. That version caught two of the three bugs on its first run. **To check a property
  is real, break the code it describes and confirm it goes red.**

- **A precondition reading a different source of truth than the code under test is silently
  false.** The verifier-outage property gated on `gate.shouldRevert()`. But the mock gate can
  be in `perHash` mode *simultaneously*, where that flag is ignored and the revert comes from
  the evidence hash instead — so the assertion was skipped on nearly every run. It now asks the
  gate directly with a low-level `staticcall` and distinguishes the outcomes by
  `returndatasize`, and it returns early when no verifier is configured (where GLT
  short-circuits to `CONFIRMED` without calling anything).

- **A precondition on a 1-in-16 hash bucket is vacuous in practice even when it is vacuous
  only in theory.** The probe originally used `trackedAt(0)`, whose gate lookup reverts only
  when its own content hash lands in the right bucket — so it was silent 15 times out of 16.
  It now uses a dedicated `submitZeroHash` attestation whose `contentHash` is all zeroes,
  which is in the reverting bucket by construction.

- **Read the handler revert column.** `configureVerifier` had `vm.prank(GLT.owner())` at the
  top of the function. `vm.prank` applies to the *next* call only, so it was consumed by
  `gate.setPerHash(...)` and `setVerifier` then reverted `OwnableUnauthorizedAccount` — on
  every single call, 440 out of 440. The suite reported `1 passed` throughout, because the
  revert was inside the fuzzer's call accounting rather than a `try/catch`, so nothing
  surfaced. The fixture's verifier had never once been changed. **A handler operation whose
  revert count matches its call count is not passing.**

### The circom toolchain lessons (2026-10-07)

§6 item 2 was blocked on `circom` / `snarkjs` being absent. It is unblocked and built. Five
things cost real time, and four of them fail silently.

- **`snarkjs`'s `pi_b` is NOT the Solidity verifier's layout.** This was the big one. Copying
  `proof.pi_a / pi_b / pi_c` into the `verifyProof(uint[2], uint[2][2], uint[2], uint[4])`
  arguments produces a proof that `groth16.verify` in JavaScript **accepts** and the EVM
  **rejects**, with the only symptom being `proof rejected` on every single submission. Each G2
  row needs its two coordinates swapped, and `snarkjs.groth16.exportSolidityCallData` is what
  performs that swap. `genproofs.js` now takes the encoding from there and *asserts* the flip
  happened. If you hand-transpose this, you will lose a day to a message that says nothing about
  the real cause.
- **`BigInt("1111...1111")` parses as DECIMAL.** `contentHash` is a hex string, so the witness
  committed to an entirely different number than the one the contract passed in. On-chain this
  looks identical to a broken proof: `proof rejected`. Found by printing the fixture's own
  `publicSignals[0]` and noticing it did not equal `contentHash`. **Hex in, `BigInt("0x" + s)`
  out** — and when a fixture and the thing it is supposed to describe disagree, print both.
- **The generated verifier reads its arguments with `calldataload`.** So the call must be
  genuinely *external*. Solidity refuses a direct internal call (memory → calldata), and the
  obvious wrapper that *does* compile — `verifyProofWith(...) { return verifyProof(...); }` —
  passes a memory pointer where the assembly expects a calldata offset and silently rejects
  every proof. Do not "simplify" `this.verifyProof(...)` into a wrapper.
- **circomlibjs returns `Uint8Array`/`BigInt` in montgomery form.** `F.toObject()` unwraps
  coordinates, and Poseidon's own return value must be unwrapped too — interpolating it
  directly yields `"47,48,34,..."`, which the witness calculator rejects with
  `Cannot convert ... to a BigInt`. Note `prv2pub` returns Montgomery `Uint8Array`, while
  `verifyPoseidon` wants that *same* form: do not mix the two representations.
- **circom 2 removed global `var`.** Constants must live inside the template, and array
  literals need `IsEqual` components for selectors — `(tier == i)` yields a boolean and cannot be
  multiplied. Also `LessThan(n)`/`LessEqThan(n)` need both operands in range, so the witness has
  to be bounded *before* the comparison, not after.
- **`snarkjs powersoftau beacon` needs a `numIterationsExp`.** Omitting it gives
  `Invalid number of parameters`. And `groth16 setup` requires `powersoftau prepare phase2`
  first; skipping it leaves a zero-byte `circuit_0000.zkey` and the misleading
  `Powers of tau is not prepared`.

### The verifier's trust boundary (2026-10-07)

Two design points that are easy to get wrong and were checked by breaking them (§5's
vacuous-property rule applied to a circuit rather than a contract).

- **The circuit proves *a* signature, not *whose*.** Without a device registry, anyone can
  generate a valid `REFUTED` for anyone else's `evidenceHash` and permanently block their
  finalization. `CircomVerifier.approvedDevice` is therefore the actual trust boundary, and
  `submitProof` is permissionless — gating submission on the owner would hand one key the power
  to suppress a `REFUTED`, which is the same single-point-of-failure shape as letting the owner
  settle disputes directly.
- **`deviceKeyHash` must be bound to the signing key inside the circuit**
  (`deviceKeyHash === Poseidon(Ax, Ay)`). The public key is a *private* witness input, so
  without that constraint a prover signs with a key they invented and then *asserts* an approved
  hash. The pairing would pass, the registry check would pass, and the gate would be closed at
  will. Confirmed by removing the constraint and regenerating: the unapproved device's proof
  then verifies.
- **`REFUTED` is a proof, not an absence.** `verdict === inEnvelope.out` pins the verdict to the
  envelope check on the private witness, so a prover cannot relabel an in-envelope reading as
  `REFUTED`. This one cannot be tested from Solidity at all — there, the verdict is simply part
  of the proof's public signals, so the pairing fails for a different reason. Verified by
  removing the constraint, rebuilding, and asking the prover directly: the witness is accepted
  with the constraint gone and rejected with it in place. **Some properties of a ZK system are
  only observable from the prover side.**
- **Out-of-field evidence hashes are refused, not reduced.** `hash` and `hash - SNARK_FIELD`
  encode to the same field element, so reducing would let one attestation read another's
  verdict. But the BN254 field is 254 bits and a `bytes32` is 256, so **~81% of uniformly random
  bytes32 values are out of field** — `keccak256` output included. A submitter that picks a hash
  without checking finds every submission reverting with `NotInField`. Nothing is lost (the
  verdict stays `UNRESOLVED`, which routes to the curator panel rather than minting), but a claim
  meant to be machine-checkable silently never becomes so. `isProvable(bytes32)` exists for this,
  and the 81% figure is asserted in a test rather than trusted.
- **The circuit cannot express `SNARK_FIELD` at all** (circom 2 has no global `var` and a
  254-bit constant is not worth bitslicing), so the check lives in the contract. That is not a
  workaround, it is the right place: the contract is the only place a `bytes32` enters.

### The referral-path bugs (2026-10-05)

The invariant fixture deployed with `address(0)`, which makes every verdict `CONFIRMED`. That
left the entire non-`CONFIRMED` half of the contract unreachable from the stateful suite: a
panel ruling on an **unchallenged** attestation, and the `panelOverride` such a rejection
sets. Adding a switchable gate exposed it immediately. All three were invisible to 115 green
tests, including 10 green invariants.

1. **Silence and ties recorded a human overruling that never happened.** `expireReview`
   defaults a stalled panel to *reject* — by design, so a deadlocked panel can never slash an
   innocent submitter. But `_resolve` set `panelOverride` on any rejection, including that
   default and including an exact tie where the panel ruled on nothing. `panelOverride` is what
   makes a `REFUTED`/`UNRESOLVED` attestation finalizable, so the sequence was: submit
   refuted evidence, get quorum-signed, let the window close, let the review window lapse
   without anyone voting, and the mint gate opens. Because the challenge window is absolute
   and already shut, nothing could ever revisit it — permanent, silent approval. Now requires
   `rejectWeight[id] > upholdWeight[id]`.

2. **A panel could be re-opened after it had ruled.** The 2026-10-02 session made each
   curator's *own* ballot permanent, which closed half of the re-ruling exploit. Nothing
   stopped a *different* curator voting afterwards. On a **challenged** attestation the
   clearing of the challenger list refused late ballots by itself (`NoChallengesToResolve`), so
   this was unreachable there — but on the **referral** path the challenger list was already
   empty, so `castCuratorVote` and a second `tallyDispute` were both accepted. Weights kept
   moving after `_settleCurators` had released locks and slashed dissenters, so the record of
   the ruling stopped describing the ruling that was applied. Fixed with `panelSettled[id]`.
   Note the verdict could **not** be flipped: settling as a rejection requires
   `rejectWeight >= 50%` of the panel, so disjoint late voters can never strictly outweigh it.
   The damage was the frozen record, and `disputeUpheld` / the slashing leg being re-runnable
   on a settled attestation. I initially wrote the test expecting a flip and had to correct it
   — see the note in `test_NoCuratorMayVoteAfterThePanelHasRuled`.

3. **An uphold left `panelOverride` behind.** A refused referral returns to `PENDING` and can
   be challenged again, so it can be ruled on a second time and upheld. The flag then survived
   on a `SLASHED` attestation, and an integrator reading `panelOverride` would treat a punished
   submission as human-approved. `_resolve` now clears it on uphold.

- **A property that forbids the feature it describes gets "fixed" by deleting the feature.**
  My third attempt asserted an overridden attestation is never terminal, and failed on the
  override's *intended* use — finalizing is exactly what it enables. Corrected to "a *slashed*
  attestation never carries one", which is a real property and which bug 3 violates.

### The audit-sweep findings (2026-10-08)

A pre-audit pass over the whole surface, hunting the six patterns in `AGENTS.md`. Two real
fund-loss bugs and one quorum gap, all invisible to 155 green tests including 10 green
invariants. 155 → 156 tests, runtime 22,819 → 23,020 B, EIP-170 margin 1,757 → **1,556 B**.

**1. A forfeited bond was the challenger's whole balance, not what they pledged.** Both
`_forfeitChallengeBonds` and `_penalise` read `challengeBond[c]`, the account total, where the
amount committed to one challenge is `challengeLock[id][c]`. `challengeLock` exists precisely to
make the release exact — its own comment says so — so this is the same per-record/aggregate
confusion that produced the earlier settlement bugs, aimed at the challenger's own pocket.

A challenger with 300 bonded who pledged 100 to each of two disputes lost 300 when the first
was thrown out. Worse, the second pledge was then already gone while its challenge was still
open, so on the uphold it forfeited **nothing** and still drew a share of a pool the other
challengers funded. That is a free second challenge, which is the entire griefing vector the
bond exists to close. It does not show up as insolvency — the tokens burned are the
challenger's own — so no solvency invariant could ever have caught it. Both legs now use the
pledge.

**2. A sub-quorum panel could overrule the machine.** `finalizeAttestation` and the
`panelOverride` gate are not the only places a quorum matters: `_resolve` set the override on
any `rejectWeight > upholdWeight`, while `tallyDispute` checks the snapshotted
`curatorQuorumWeight` and `_resolve` did not. So one curator holding 100 against a 150 quorum
acquitting at expiry opened the mint gate permanently on a `REFUTED` attestation — the same
"silence is not acquittal" bug as 2026-10-05, on the quorum axis rather than the tie axis. The
existing invariant checks `rejectWeight > upholdWeight`, so it cannot see this: a sub-quorum
majority satisfies it. Both conditions now hold together.

The `REFUTED` half of this fix needed a second change to avoid becoming a dead end. A panel
short of quorum can neither overrule a refutation nor be overruled by it, so expiry now leaves
the machine's finding standing and penalises the submitter, which terminates. A quorum of
curators can still overrule it.

**3. OPEN — an `UNRESOLVED` attestation can be stranded permanently.** This one is *not* fixed
and is the most important thing in this entry. `expireReview` on a `UNRESOLVED` attestation
whose panel tied or was silent leaves it `PENDING` with `panelOverride` false. From there:
`finalizeAttestation` reverts `EvidenceNotFinalizable` on a verdict that can never change to
`CONFIRMED` (only the owner sets the verifier, and a broken verifier is the normal cause);
`challengeAttestation` reverts `ChallengeWindowClosed`; `castCuratorVote` reverts
`AlreadyRuled` on `panelSettled`; `tallyDispute` reverts `CuratorsSplit`; `expireReview` again
is a no-op because `curatorVoters` is empty. **`minStake` per attestation is held by the
contract with no exit at all.** This is not new — `test_TiedPanelAtExpiryDoesNotOverrideTheMachine`
and `test_UnattendedExpiryDoesNotOverrideTheMachine` pin it as intended — and finding 2 makes it
slightly broader. Under a reverting verifier *every* attestation is `UNRESOLVED`, so an outage
strands a stake per attestation rather than one.

Why it was left alone: the alternative to a stranded stake is a minted reward on evidence the
gate refused to confirm, and a lock strands one submitter's own funds while a mint dilutes
every holder. That is a call about what GLT promises, not a bug fix, and `_resolve` is on the
ask-first list. It needs a third terminal state — release the stake, mint nothing, e.g. a new
`EXPIRED` status — which costs EIP-170 bytes out of the remaining 1,556 B. **§6 item 7.**

#### How these were verified

`script/vacuity-check.sh` reverts each fix on its own and requires a test to go red. All four
pass. Two of the four were **vacuous on the first run** and the check is why that is known
rather than shipped:

- Reverting the `_penalise` leg alone changed nothing, because both my tests had every
  challenger pledging their entire balance on each dispute. Asserting `payoutPool` explicitly
  made it observable.
- Reverting the `panelOverride` quorum check alone changed nothing, because the `REFUTED`
  expiry fix means a sub-quorum `REFUTED` panel never reaches `_resolve(false)` — it slashes.
  **The two fixes mask each other.** The quorum gap is only reachable on `UNRESOLVED`, and the
  2026-10-05 tests covered a tie and silence but never "a minority showed up and lost". Adding
  that case turned it red.

Two lessons worth keeping, both about the check itself:

- **A revert that fails to apply reads as a vacuous property.** The first version used regex
  for multi-line Solidity and silently matched nothing, so the fix stayed in, the test passed,
  and the output said VACUOUS. It now uses exact string replacement and asserts the file
  changed before trusting the result.
- **Reverting in the wrong direction proves nothing either.** One revert removed the whole
  `expireReview` condition, making the contract *stricter* than the bug, and the tests accepted
  it. Green there is not a weak property; it is not the bug being tested.

### The deploy-script lessons (2026-10-05)

Testing `Deploy.s.sol` against Anvil found two things that reading it could not.

- **`proposers[0] = msg.sender` named the script contract, not the deployer.** Inside
  `vm.startBroadcast`, `msg.sender` is not the broadcasting account. The timelock's only
  proposer was an address nobody holds a key for, so the deployment was permanently
  ungovernable while every constructor argument looked correct. Now `vm.addr(pk)`.
- **`registerCurator` cannot be called by the deployer at all.** It is `onlyOwner` and the
  owner is the timelock. An earlier version called it at the end of `run()` and reverted
  `OwnableUnauthorizedAccount` against the live node. There is no inline path to it, so the
  call is gone and the post-deploy sequence is documented instead: schedule through the
  timelock, then each curator funds its own bond. **The panel is dead until they do**, and it
  fails silently — every parameter looks healthy.
- **Anvil needed `anvil_increaseTime`, not `anvil_mine`.** Mining blocks does not advance the
  clock far enough for a two-day timelock; `execute` reverted `TimelockUnexpectedOperationState`.
- **`forge script` looks for an entry point named `run`.** A `verify()` function is unreachable
  from the CLI: "Function `run` not found in the ABI".
- **`TimelockController` must be constructed with `admin = address(0)`.** With an admin set,
  that key can re-point the proposer and executor sets at will, silently restoring single-key
  control over everything the timelock governs, including `transferOwnership` of GLT.
- **`vm.envUint` reverts on a missing key.** Any run command predating `TIMELOCK_DELAY` failed
  on a variable the script no longer needed. `vm.envOr` with a stated default is correct here.

### The 47-green-tests trap (2026-09-30)

The suite was 47/47 and still shipped four fund-loss bugs, because every test exercised
one challenger, one dispute, and a well-behaved owner. **The bugs were all in the N-user
and adversarial-owner cases.** Write the adversarial tests first next time: two challengers,
a hostile owner, an exit mid-dispute. A green suite means the happy path works, nothing more.

### The invariant suite lessons (2026-10-02)

- **It found a real bug on its first run, which is the entire argument for having written it.**
  `invariant_TerminalAttestationsRetainNoStake` failed: a FINALIZED attestation still reported
  `stake == 100e18`. `finalizeAttestation` decremented `totalStaked` and returned the tokens but
  never cleared `att.stake`, while `_penalise` *does* clear it. Solvency was never at risk —
  `totalLiabilities()` reads `totalStaked`, which was already correct — so all 105 existing tests
  and all 5 fuzz suites passed straight through it. But the public record lied, and anything
  integrating against `stake` would have over-counted. This is the mirror image of the
  `totalStaked` bug below: there the balance was right and the book wrong, here the book was
  right and the *record* wrong. **An assertion over per-record state catches a class no
  aggregate invariant can.**

- **The bug was 20 lines from a line already carrying the same logic.** `_penalise` at
  `totalStaked -= att.stake; att.stake = 0;`, `finalizeAttestation` at `totalStaked -= att.stake;`
  and nothing after. Symmetry between settlement paths is worth checking explicitly, because the
  aggregate assertions confirm both are *financially* fine and neither notices that only one
  updates the record.

- **Handler rules that decide whether the suite is usable.** Two, both learned the hard way:
  **(1) No handler call may revert** — every external call into GLT is wrapped in `try/catch`,
  because a reverting handler aborts the entire run and reports it as a handler failure rather
  than a contract bug. **(2) All handler state must be `internal`** — public state variables
  generate getters, and the fuzzer calls those alongside the real operations.

- **`forge-std` 1.16.2 has no `FuzzedContract`.** Newer tutorials use
  `FuzzedContract(address(glt)).addr()`. Here it does not exist; handlers take plain typed params
  (`uint256 actorSeed, uint256 idSeed`) and the fuzzer binds raw calldata to them. Fine, and it
  keeps the handler signature readable.

- **Invariant cost is dominated by the checks, not the calls.** Trimming 128,000 calls to 8,000
  (16x) cut the suite from 205 s to ~10 s only once the config actually took effect — the first
  attempt looked broken because `invariant_runs` written at the top level was ignored entirely,
  so the sweep never shrank. **Verify a config change took effect before trusting the timing.**

- **Cap how many ids the handler remembers** (`MAX_TRACKED = 48`). The iterating invariants are
  O(ids) and ids grow with sequence length, so without a cap every check gets quadratically
  more expensive. The iterating invariants use `assertLe` rather than equality for the same
  reason: the book legitimately covers attestations the capped handler never observed.

### The curator bond lessons (2026-10-02)

- **Clearing the ballot at settlement opened a re-ruling exploit.** `_settleCurators` originally
  reset `curatorBallot[id][c] = 0` so the slot could be reused. But `upholdWeight` and
  `rejectWeight` are *never* reset at settlement, so a cleared ballot let a curator stack a
  second vote onto an already-decided tally: three reject votes settle as a rejection, then two
  of them re-vote uphold and the same attestation tallies as **upheld** — `_penalise` on a
  submitter the panel had just exonerated, with no challenger anywhere in the picture. The
  ballot is now permanent for the life of the attestation. **Any per-participant record cleared
  at settlement must be checked against the aggregates it fed, which are not cleared.**

- **A bond is only real if it cannot be withdrawn before the slash.** The obvious leak was
  bond → rule → deactivate → withdraw, immune when the ruling turned out to be the losing one.
  `curatorOpenVotes` counts unsettled ballots and blocks withdrawal. Note deactivation is *not*
  enough on its own: it is immediate in effect and reversible by the owner, so it is not a
  commitment to anything.

- **Every terminal path that consumes a vote must release its lock.** A curator may rule on a
  referral with no challenger (`UNRESOLVED` needs none). If the verifier is then repaired, the
  attestation finalizes through the normal path and `_resolve` never runs — so the vote lock
  would be held by nothing that can ever clear it. `finalizeAttestation` calls
  `_settleCurators(..., penalise = false)`: locks released, nobody slashed, because those votes
  were *abandoned*, not overruled. **A new exit path needs the same cleanup as the old ones.**

- **Test churn after adding a bond is the feature working, not a regression.** 12 tests failed
  with `BondBelowRequired(0, 1e21)` on the first run. That is the gate denying unbonded curators,
  which is the entire point. Every curator in all three setUps now bonds.

- **Reusing a participant after slashing fails in instructive ways.** Once a dispute is upheld,
  attester1's attester bond is gone and challenger1's challenge bond is forfeited, so a later
  `_sign(id, attester1)` or `challengeAttestation` reverts on *their* bond, not the thing under
  test. Five of my new tests failed this way before I switched to the untouched `attester2` /
  `outsider`. **When a test spans two disputes, use fresh participants for the second one.**

- **`curatorQuorumWeight()` is basis-points of total weight, not the total.** Asserting against
  `type(uint128).max` + 200 rather than `(type(uint128).max + 300) * 5000 / 10000` fails. Also:
  `200 + type(uint128).max` is evaluated in **uint128** and overflows — write
  `uint256(type(uint128).max) + 200`.

- **A panel that reached quorum with a clear non-tie must be settled by `tallyDispute`, not
  `expireReview`** — the latter reverts `ReviewAlreadyResolved` on purpose. Expiry is only for
  stalls (no quorum, or a tie).

- **The tri-state gate is tri-state, and the panel can still overrule it — visibly.** On a
  `REFUTED` verdict: silence at expiry punishes the submitter, but a panel that actually votes
  to acquit spares them, sets `panelOverride`, and the attestation becomes finalizable. Curators
  who acquit are *not* slashed, because they agreed with the ruling. Pinned by
  `test_RefutedExpirySparesASubmitterThePanelAcquitted` so it stays a deliberate property.

### Original 2026-09-30 findings (kept)

- **Anyone could drain the challenge payout pool.** `claimChallengeReward` checked only
  `hasClaimed`, and `_penalise` had already `_clear`ed the challenger list, so the *first*
  caller to invoke it took the whole pool. Caught by `test_RevertWhen_NonChallengerClaims`.
  Fixed with a persistent `wasChallenger` mapping that survives the array clear, checked
  before the claim. **Do not gate payouts on the transient array.**

- **A rejected dispute stranded the challenger's bond** — neither returned nor slashed, just
  locked in the contract forever, which left challenging free and so kept the griefing vector
  open. Fixed with `_forfeitChallengeBonds`.

- **A single `onlyOwner` curator could slash honest attesters.** Replaced with a weighted
  panel: `castCuratorVote` + `tallyDispute`, needing quorum and a non-tie. Note the weight
  is still assigned by the owner, so this decentralises the *ruling* but not the *appointment*.

- **A colluding quorum was free.** The original design slashed only the *submitter* of a
  fabricated attestation. The attesters who actually certified the lie lost nothing — they could
  sign garbage indefinitely, letting someone else eat the penalty. Fixed with per-attester bonds
  plus a slashing leg in `_penalise`. This was the single largest correctness gap in the
  original design. **Do not regress it.**

- **A single challenger could freeze any attestation.** v1 flipped status to `DISPUTED` on the
  first challenge, so any random address could block finalization until the owner manually
  resolved — a protocol-wide griefing vector from a one-wallet attacker. Fixed by letting
  challenges accumulate; escalation is now a curator-quorum event.
  `test_ChallengeDoesNotFreezeSignatures` guards it. **Do not reintroduce single-challenger
  escalation.**

- **`delete` does not work on a local storage pointer to a dynamic array** (`delete ch` where
  `ch` is `address[] storage` → compile error 9767). Use a `pop()` loop helper, `_clear`.

- **I declared an event param as `address indexed id` when the argument was `bytes32`.** The
  error pointed at the *call site*, not the declaration, and renaming the event just moved the
  caret. When solc complains that a `bytes32` arg needs an `address`, check the event
  *declaration* before the call.

- **`_penalise` burns tokens the contract holds**, so the contract must actually hold the full
  attester and challenge bonds. Test setup funds them by transferring from the treasury —
  there is deliberately no `mintForTest`. Adding one would leave an unguarded mint in a live
  token. Assert on the `BOND`/`CHALLENGE_BOND` components, not raw `balanceOf(address(this))`,
  since the held total changes whenever you add a new bond type.

- **Foundry `vm.expectRevert(bytes4)` requires EXACT revert data in the current version**, not a
  selector prefix. Use `abi.encodeWithSelector(...)` or `vm.expectPartialRevert(...)`.
  Bit me on a test that passed the selector and failed on the parameterised error.

- **OZ 5.7 diamond:** `ERC20Permit` and `ERC20Votes` (via `Votes`) both inherit `Nonces`, so an
  explicit `nonces()` override is required. Also `ERC20Votes` in 5.7 has **no constructor** —
  `ERC20Permit` supplies the EIP712 init.

- **No test-only mint helpers.** Deliberately not added — an unguarded `_mint` left in a
  token contract is a backdoor. Initial supply is a constructor arg instead
  (`initialSupply`, `treasury`).

- **`attestation()` and `getAttestation()` were duplicates** — left in for ergonomics. Collapsed
  2026-10-02: the bare `attestation()` getter had **zero call sites** across all three test
  files, so removing it cost nothing and saved 26 B. `getAttestation` is the survivor because it
  is what all 41 call sites use. Done before any external integration, as intended.

- **Error and event name collision:** `AttestationChallenged` existed as both. Error renamed to
  `AttestationUnderChallenge`. Watch for this when adding members.

- **Enum comparisons in `assertEq` need casts on both sides:**
  `assertEq(uint8(att.status), uint8(AttestationStatus.PENDING))`.

- **Test arithmetic trap (mine, twice):** `submitAttestation` locks stake immediately, so a
  balance captured *before* submission must be compared against `+ MIN_STAKE + REWARD` after
  finalization, not `+ REWARD`. Also `totalSupply` drops by the burned stake on an upheld
  dispute — it is not a constant.

- WSL had no Linux Node when this was first recorded; `node` was absent and `npm` resolved to
  the Windows binary via `/mnt/c`. **Re-checked 2026-10-06: `/usr/bin/node` is now present at
  v22.22.1**, but `npm` still resolves to `/mnt/c/Program Files/nodejs/npm` and `circom` /
  `snarkjs` are still absent. So a Node runtime exists; a circom toolchain does not.
  Irrelevant for Solidity, but do not assume the toolchain is complete — check each binary.

- **`payoutPool` cannot represent N independent claims.** It stored the per-challenger
  `each`, and `claimChallengeReward` zeroed it, so with 2 challengers the first to call took
  its share and the second reverted `NothingToClaim` with its bond stranded forever. Fixed
  with a per-challenger `payoutShare[id][addr]`. **The `wasChallenger` fix from the earlier
  session fixed the wrong half of this bug** — it stopped an outsider draining the pool but
  left multi-challenger payout broken. A pull-payment pool needs per-claimant accounting.

- **`recoverExcessStake` was an owner rug on live escrow.** It burned any amount from the
  contract balance, but that balance is *entirely* pending stakes + bonds + unclaimed
  payouts. Burning a PENDING attestation's stake then finalizing it left the submitter
  "repaid" out of the attester bond pool, and the next `withdrawAttesterBond` reverted.
  Now every token the contract owes is tracked in `totalLiabilities()` and only the
  unbacked remainder is burnable. **Maintain that total on every token movement**, or the
  invariant is decoration.

- **Challenge bonds were withdrawable mid-challenge.** Fund, file, withdraw instantly — a
  rejected dispute then had nothing to burn, so the anti-frivolity guarantee did not exist.
  Now `lockedChallengeBond` gates withdrawal and `_releaseLock` frees it at settlement. The
  per-attestation `challengeLock[id][addr]` figure exists so a mid-dispute
  `setChallengeBondAmount` cannot leave an account permanently locked.

- **Bond amounts defaulted to 0.** A fresh deploy allowed free challenging *and* free
  signing, reinstating the exact griefing vector the bonds were added to close. Only the test
  setup ever set them. Defaults are now 100e18 and `setChallengeBondAmount(0)` reverts.

- **`totalStaked` must lose the WHOLE stake on `_penalise`, not just the burned leg.**
  Subtracting only `burn` double-counts the remainder as both submitter stake and challenge
  payout, so `totalLiabilities()` exceeds `balanceOf(address(this))` and the contract looks
  insolvent. Found by `testFuzz_SettlementConservesTokens`, not by any deterministic test —
  the balance was always exactly right, only the *book* was wrong. **The invariant is not
  "the arithmetic balances", it is "held >= owed".**

- **`payoutPool` holds the TOTAL, not the per-head share.** The old code stored `each` and
  the fuzzer read it back as a per-head figure. Two ways to be wrong about the same field:
  writing it wrong (bug 2, only one of N challengers paid) and reading it wrong.

- **Fuzz found a double-vote in my own test, not the contract.** A tie case that had curator1
  voting twice tripped `AlreadyVoted`. Always assign distinct curators per branch when
  fuzzing vote patterns.

- **`submitAttestation` id collides within a single block.** The id is
  `keccak256(submitter, contentHash, timestamp, secret)` and Foundry does not advance
  `block.timestamp` between calls, so repeated submissions with the same secret silently
  return the same id and overwrite each other. Use a per-call nonce in every test that needs
  more than one live attestation — this produced three baffling failures.

- **The contract could not be deployed at all.** 38,446 B runtime against the 24,576 B
  EIP-170 limit, because the optimizer was off and `foundry.toml` never enabled it. Fixed
  with `optimizer = true`. **Run `forge build --sizes` as part of the build, not just
  `forge test`** — the test suite passes happily on undeployable bytecode.

  The curator bond then cost 1,829 B on top of that, taking margin from 3,254 B to 1,425 B.
  Reclaimed on 2026-10-02: dropping the duplicate `attestation()` getter (−26 B, it had **zero**
  call sites) and `optimizer_runs` 200 → 20 (−536 B). Now **22,563 B, 2,013 B of margin.**
  See the measured table in `foundry.toml`; re-run `forge build --sizes` on every change.

  - **`optimizer_runs` is a size/gas dial, and it is monotonic.** Measured across the
    settlement-heavy tests: 200 → 23,125 B / 7,097,582 gas; 20 → 22,563 B / 7,130,001;
    1 → 22,516 B / 7,241,474; 999999 → 29,809 B and **-5,233 margin, i.e. undeployable.**
    20 takes ~95% of the size win for ~23% of the gas cost.
  - **The old `foundry.toml` comment claimed high turns were pinned low because of "a large gas
    regression" on the settlement loops. That was wrong — the worst case is 2.03%, and 0.46%
    at the chosen setting.** The claim had been carried across sessions unverified and was
    costing 536 B of deployability margin. **Do not trust a recorded measurement you have not
    re-run; this one was wrong in the direction that looked responsible.**
  - **`via_ir` re-measured and still worse.** 23,382 B vs 23,125 B on the same build (+257 B),
    and 3m36s to compile instead of seconds. Stays off.
  - **When EIP-170 margin and gas conflict, EIP-170 wins.** It is a hard cliff that makes the
    contract undeployable; gas is a soft recurring cost on a token with no real throughput yet.

- **`_resolve` must set `panelOverride` before clearing the challenger list.** It is
  conditional on the *current* verdict and, when there were challenges, on there being none.
  Getting that order wrong deadlocks the attestation permanently: `finalizeAttestation` blocks
  on the verdict, `challengeAttestation` is closed by the window, and `castCuratorVote` sees
  the curator already voted. Reachable in production via a REFUTED attestation that someone
  disputes and the panel then rejects.

- **`submitAttestation` id collisions.** The id is `keccak256(submitter, contentHash,
  timestamp, secret)`. Foundry does not advance `block.timestamp` between calls, so two test
  submissions with the same secret silently return the same id and the second overwrites the
  first. Use distinct secrets (`_submitDistinct`) when a test needs several live records.
  On-chain this is a same-block resubmission of the same evidence, which is harmless.

- **A challenge window is absolute, not relative.** Warping forward to settle one dispute
  closes the filing period for every attestation submitted alongside it. File all challenges
  before any warp.

- **`/usr/bin/forge` is ZOE, not Foundry.** A 2013 estimation tool that shadows the real
  binary on the default PATH. Symptom: `forge test` prints `ZOE ERROR ... unknown option`.
  Found only by testing resume in a clean shell — `forge` was resolving to the wrong program
  the whole time. Both `~/.bashrc` and `~/.profile` now prepend `~/.foundry/bin`.
  **Re-confirmed 2026-10-02 in a nastier form: the fix only covers *interactive* and *login*
  shells.** A helper invoked as `bash script.sh` sources neither, so `~/.foundry/bin` never
  reaches `PATH` and ZOE wins silently — a size/build probe came back as seven consecutive
  `BUILD FAILED` lines that were never build failures at all. **In any script, call
  `/home/alexa/.foundry/bin/forge` by absolute path.** Symptom to recognise: `ZOE ERROR ...
  zoeParseOptions: unknown option`.

- **Do not append to `~/.bashrc` via a shell heredoc.** The layers between PowerShell,
  `wsl.exe` and `bash` expanded `$PATH` during the append, freezing a ~2 KB absolute PATH
  (including every Windows mount) into the file. Write the line with a literal `\$PATH`, or
  use a heredoc with a quoted delimiter that survives the round trip. Verify with
  `tail -3 ~/.bashrc` and check the line is short.

---

## 6. Next actions, in order

Closed so far: 1 (git remote), 2 (deactivation guards), 3 (invariant handler), 4 (README),
5 (deploy script on Anvil), 8 (verifier in the fixture), **2 (circom verifier — closed
2026-10-07)**, plus the curator bond and size reclamation from 2026-10-02. What remains:

1. ☐ **External audit before any mainnet deploy with real value.** This is now the *only*
   engineering item left that gates shipping, and it is not optional. An unaudited contract
   that mints a token people pay real money for is not a smaller version of this one, it is a
   liability. Hand the auditor §5 as the list of what has already gone wrong here — it is an
   unusually good map of where to look, and the 2026-10-05 referral bugs are exactly the class
   an auditor would have charged most to find.

   Specifically worth asking about: the `expireReview` default-reject path, whether
   `panelOverride` + `panelSettled` can still be reached in a combination that deadlocks funds
   (**it can — see §5 finding 3, which is known and unfixed**), whether the `ERC20Votes`
   checkpoint machinery interacts badly with `_burn` during settlement, and whether any other
   settlement leg still reads an account aggregate where a per-record figure is owed. That last
   one is the 2026-10-08 forfeit bug, it survived 155 green tests and 10 green invariants, and
   it is the single strongest argument for handing an auditor §5: the class of error here is
   systematic, not a one-off.
2. ✅ **Circom verifier — CLOSED 2026-10-07.** `circuit/evidence.circom` (7,513 constraints at
   the first build; now 4,861 with the Poseidon signature scheme) + `src/CircomVerifier.sol`,
   exercised by 25 tests against genuine Groth16 proofs. The toolchain was unblocked by
   installing `circom` 2.1.9 to `~/.local/bin` and `snarkjs` + `circomlibjs` to
   `~/.localtools/snarkjs` (npm installed via `corepack npm`, since `npm` on PATH is the
   Windows binary). What it proves and — more importantly — what it does not: §5 "The verifier's
   trust boundary". **It is not set on any deployment**, so `verifier` remains `address(0)` and
   every verdict is still `CONFIRMED` in practice; wiring it up is a deployment decision, not
   an engineering one, and it belongs in the audit conversation.
3. ☐ **Testnet deploy**, then `Verify` against it. Anvil confirmed the mechanics and surfaced
   two script bugs; a testnet will confirm the gas costs, which no local run has.
4. ☐ **Re-check EIP-170 margin before landing each of the above.** Now **1,556 B**, down from
   1,757 B: the 2026-10-08 audit sweep spent 201 B on two fund-loss fixes, which is what margin
   is for. The verifier is a separate 3,618 B contract and cost the token nothing. If a future
   change overruns, take `optimizer_runs` 20 → 1 (buys 47 B for ~1.6% gas, measured) or cut
   surface before raising the bar.
5. ☐ **Decide whether the ~81% out-of-field hash rate is acceptable** (new, 2026-10-07). Not a
   bug — refusing out-of-field hashes is required for soundness — but it means most submitters
   will never get a machine verdict unless they pick an in-field `contentHash`. Options, in
   order of preference: require submitters to pass `isProvable(hash)` before submitting;
   constrain `contentHash` at submission time in GLT (costs EIP-170 bytes in the token, which
   is currently scarcer than they seem); or accept that only device-attested evidence is ever
   machine-checked, which is arguably the honest scope anyway. **Do not fix this by reducing
   the hash modulo the field** — that reintroduces the cross-attestation collision the check
   exists to prevent.
6. ☐ **Legal wrapper** (Wyoming DAO LLC) if this is ever to hold real money. Nothing here is
   legally binding; §2 records why that is not a Solidity problem at all.
7. ☐ **New, 2026-10-08 — and it is a design call, not a bug.** An `UNRESOLVED` attestation
   whose panel tied or stayed silent at expiry is `PENDING` with no reachable exit, and its
   `minStake` is held by the contract forever. Full mechanism, and why the alternative is
   worse, in §5 "The audit-sweep findings" finding 3. Needs a third terminal state: release the
   stake, mint nothing, e.g. a new `EXPIRED` status. **Do not fix it by setting
   `panelOverride` on a deadlocked panel** — that is the 2026-10-05 bug, reintroduced.
   Whether to spend the remaining margin on it, or to hand it to the auditor as a known and
   documented limitation, is the actual question.
### Not on the list, deliberately

- **Off-grid settlement.** §2 item 1. Physically impossible as specified; a store-and-forward
  design is salvageable but is a different project.
- **Pillar 2, access-gating / query fees.** Unbuilt. Adding it now would spend scarce EIP-170
  margin before an audit has said what the 1,556 B should be spent on.
- **Removing `secretRevealed` / `disputeUpheld` from the ABI.** Both have 0 external call sites
  but are meaningful public record — `secretRevealed` is what a consumer reads to know a
  pre-image was disclosed, and `disputeUpheld` is the ruling. Removing them to save bytes would
   be cutting the audit trail, not dead code.

---

## 7. Reality check on priorities

GLT is a real build with a defensible thesis, but it is **not** the thing with a clock on it.
`~/bounty/SESSION.md` §3 has three unchecked bounty accounts, and identity verification (§3.2)
takes **days to weeks**. That gates the whole income pipeline and gets no cheaper by waiting.
GLT will be in exactly this state in a month either way.

Sequence: do the accounts, then come back here.
