# SESSION STATE — Galactic-Trust (GLT) / GCIA epistemic ledger
> Re-read this file first every time you resume. This is the single source of truth for GLT.

**Last updated:** 2026-10-02
**Operator:** alexa @ Ubuntu 26.04.1 (WSL2)
**Location:** `~/galactic-trust` (917 src / 2595 test lines Solidity)
**Status:** invariant suite, curator bond, escrow accounting, 112/112 tests green
(default profile 10 s; `deep` profile = 5 fuzz suites at 2000 runs + 7 invariants at
128,000 calls each), NOT deployed, NOT audited.

---

## 1. Current status

| Item | State |
|---|---|
| Foundry toolchain | ✅ installed at `~/.foundry/bin` (forge 1.5.1) — **needs PATH export, see §3** |
| `GalacticTrust.sol` | ✅ compiles, quorum attestation + challenge window + slashing |
| Test suite | ✅ 112/112 passing (78 unit + 22 adversarial + 5 fuzz + 7 invariant) |
| Tri-state evidence gate | ✅ `CONFIRMED`/`REFUTED`/`UNRESOLVED`, enforced at finalize |
| Verifier outage failsafe | ✅ a reverting verifier → `UNRESOLVED`, never a protocol halt |
| Curator quorum snapshot | ✅ snapshotted at submission, owner cannot move it mid-dispute |
| Dispute tie-break | ✅ `expireReview` after `REVIEW_WINDOW` (7 days), rejects by default |
| Commit-reveal gating | ✅ post-window, challenger-or-curator only, verify-and-emit |
| Fuzz suite | ✅ conservation + multi-challenger payout + expiry terminality + curator slash |
| **Invariant handler** | ✅ **7 stateful properties, 15 handler ops — §6.3 closed, found 1 bug** |
| **Curator stake behind appointment** | ✅ **bonded, locked while voting, loser's bond slashed — §6.1 closed** |
| Escrow solvency invariant | ✅ `totalLiabilities()` accounted on every movement |
| Owner burn limited to unbacked balance | ✅ `recoverExcessStake` cannot touch live escrow |
| Challenge bond locked while challenge open | ✅ `lockedChallengeBond` |
| Contract size within EIP-170 | ✅ 22,570 B — 2,006 B margin |
| Deploy script | ✅ written, untested against a live RPC |
| Attester bonds + attester slashing | ✅ built and tested |
| Challenge bonds | ✅ built — required to challenge, forfeited if rejected |
| Weighted curator panel | ✅ built — `onlyOwner` ruling replaced |
| Bounded settlement loops | ✅ `MAX_SIGNERS`/`MAX_CHALLENGERS`/`MAX_CURATORS` caps + pull payments |
| Access-gating / query fees (pillar 2) | ❌ not built — separate contract |
| Real ZK verifier | ❌ `IVerifier` is wired and enforced, but no circom verifier exists yet |
| Audit | ❌ none |
| Git remote | ❌ local-only history, single disk — see §6 |
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
forge test                        # 112/112, ~10 s   (default profile)
FOUNDRY_PROFILE=deep forge test   # 112/112, ~213 s  (full sweep, pre-ship)
forge build --sizes              # MUST stay under 24,576 B EIP-170
```

**Two profiles, and the split is deliberate.** The default runs invariants at 32×250 = 8,000
calls per property so `forge test` stays usable on every edit; `deep` runs 256×500 = 128,000
calls plus fuzz at 2,000. An invariant suite nobody runs is the same as no suite, so the fast
default is the honest one and `deep` is what CI and any pre-ship run must use.

⚠️ **`invariant_runs` / `invariant_depth` at the top level of `foundry.toml` are accepted
silently and ignored.** They must be in an `[invariant]` table as `runs` and `depth`. Verified
with `forge config | sed -n '/\[invariant\]/,/^$/p'`. Same trap for fuzz: `[fuzz] runs`.

**PATH is already configured** — no manual export needed. It is set in both `~/.bashrc`
(interactive) and `~/.profile` (login), verified working from both.

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
test/GalacticTrust.t.sol    78 unit tests, lifecycle + governance
test/Adversarial.t.sol     22 tests, hostile owner / broken verifier / tie / no-challenger
test/Fuzz.t.sol              5 fuzz suites, conservation + terminality + curator slash
test/Invariant.t.sol         7 stateful invariants over a 15-operation handler
```

The adversarial and fuzz files are not redundant with the unit suite. Every real bug found in
the 2026-09-30 audit was invisible to the unit suite and visible to one of the other two.
`forge test --match-test testFuzz --fuzz-runs 2000` before shipping any change to
`_penalise`, `_resolve`, or the liability counters.

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
               │                this sets panelOverride — the humans overruling the machine.
               └─ stalled (tied, or quorum never reached)
                      → after REVIEW_WINDOW: expireReview() → rejects by default.
                        A REFUTED verdict is still punished: silence is not acquittal.
                        Unless the panel actually voted to acquit, which spares the submitter.
```

> Every terminal branch is covered by `test/Adversarial.t.sol`, and the conservation property
> by `test/Fuzz.t.sol` — read those before changing anything in `_penalise` or `_resolve`.

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

### Contract surface (`src/GalacticTrust.sol`, ~890 lines)

| Function | Line | Role |
|---|---|---|
| `fundAttesterBond` | 282 | lock GLT as signing bond |
| `withdrawAttesterBond` | 293 | reclaim bond, only after deactivation |
| `registerCurator` / `deactivateCurator` | 305 / 321 | panel appointment |
| `setCuratorBondAmount` / `setCuratorSlashBps` | 339 / 344 | curator bond + dissent penalty |
| `fundCuratorBond` | 350 | lock GLT as a curatorship bond |
| `withdrawCuratorBond` | 363 | reclaim, blocked while any vote is unsettled |
| `fundChallengeBond` | 376 | lock GLT as challenging bond |
| `withdrawChallengeBond` | 394 | reclaim only the *unlocked* portion |
| `registerAttester` / `deactivateAttester` | 402 / 418 | committee management |
| `submitAttestation` | 451 | lock stake, open window, returns `id` |
| `signAttestation` | 481 | attester co-sign, accumulates weight |
| `finalizeAttestation` | 501 | **the mint gate** — quorum + window + zero challenges |
| `challengeAttestation` | 546 | red-team flag, accumulates, locks bond |
| `castCuratorVote` | 566 | weighted panel ruling, bond-gated |
| `tallyDispute` | 596 | applies the ruling once curator quorum is met |
| `expireReview` | 620 | forces a stalled dispute after `REVIEW_WINDOW` |
| `claimChallengeReward` | 808 | per-challenger pull payment |
| `checkSecret` | 825 | stateless read-only hash check, records nothing |
| `revealSecret` | 838 | post-window, challenger/curator only, verify-and-emit |
| `evidenceVerdict` | 864 | the machine's tri-state opinion, never reverts |
| `totalLiabilities` | 869 | every token the contract owes, never burnable |
| `excessBalance` | 878 | held minus owed — the only burnable amount |
| `recoverExcessStake` | 886 | burns unbacked balance only |

Internal: `_settleCurators` (715) slashes dissenting curators and releases vote locks,
`_penalise` (743) burns the submitter stake and signing attesters.

Setters: `setVerifier`, `setQuorumBps`, `setMinStake`, `setRewardAmount`, `setSlashBps`,
`setAttesterBondAmount`, `setAttesterSlashBps`, `setChallengeBondAmount`, `setCuratorBondAmount`,
`setCuratorSlashBps` (all `onlyOwner`; both bond setters reject zero).
Getters: `challengeCount`, `signerWeight`, `attesterBond`, `challengeBond`, `curatorBond`,
`lockedChallengeBond`, `curatorOpenVotes`, `curatorBallot`, `payoutShare`, `requiredQuorumWeight`,
`getAttestation`, `attester`, `curator`.

> Bond defaults, all non-zero on purpose: `attesterBondAmount` 100e18, `challengeBondAmount`
> 100e18, `curatorBondAmount` **1,000e18** (the panel is load-bearing for every REFUTED and
> UNRESOLVED verdict). `curatorSlashBps` and `attesterSlashBps` both default to 10,000.

> Line numbers drift. Re-derive with
> `grep -nE "^\s+(function|constructor)" src/GalacticTrust.sol` rather than trusting this table.

---

## 5. Hard-won lessons / gotchas

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

- WSL has no Linux Node; `node` is absent and `npm` resolves to the Windows binary via `/mnt/c`.
  Irrelevant for Solidity, but do not assume a Node toolchain works in WSL.

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

Items 1 (curator bond), 2 (size reclamation) and 3 (invariant handler) were all closed on
2026-10-02 — see §4, §5 and §1. What remains:

1. ☐ **Add a git remote.** History is local-only, so the whole project dies with the laptop —
   the exact failure `~/bounty/SESSION.md` opens with. The cheapest high-value item on the list
   and the only one that takes five minutes. **Decided: private.** Blocked on the user for the
   remote URL — `gh` is not installed and there are no SSH keys. Also pending: the local git
   identity is a placeholder (`GLOBAL.CYBER.INTELLIGENCE@EMAIL.COM`) and should be corrected
   before the first push, since commit history is permanent.
2. ☐ **Reject `deactivateAttester` / `deactivateCurator` on unknown addresses** — they
   silently succeed today, which hides typos in owner scripts. The invariant handler exercises
   both, so a regression here will now surface as a weight-total mismatch.
3. ☐ **Write a circom verifier** implementing `IVerifier`. The interface is tri-state and the
   gate is live; there is still no real proof system behind it. Until one exists, every
   verdict is `CONFIRMED` and the gate is untested in anger. Model the unsolvable case too:
   a verifier that returns `UNRESOLVED` when a proof is malformed. Note this needs a
   circom/snarkjs toolchain and §5 records that WSL has no working Node — probably blocked.
4. ☐ **Replace the boilerplate `README.md`** (still the Foundry template). It must state
   plainly that GLT asserts *staked testimony*, never truth.
5. ☐ **Test the deploy script against a local Anvil node**, then a testnet. Both bond amounts
   now default non-zero, so the script no longer needs to set them — but it *will* need to fund
   curator bonds before the panel can rule on anything.
6. ☐ **External audit before any mainnet deploy with real value.** Non-negotiable. An
   unaudited contract that mints a token people pay real money for is not a smaller version of
   this one, it is a liability. Hand the auditor §5 as the list of what has already gone wrong
   here; it is a useful map of where to look.
7. ☐ **Re-check EIP-170 margin before landing each of the above.** 2,006 B is roughly two small
   features. If one of items 2–5 overruns, take another `optimizer_runs` step down (20 → 1 buys
   47 B for 1.6% gas) or cut surface before raising the bar.
8. ☐ **Add a verifier to the invariant fixture.** It currently deploys with `address(0)`, so every
   verdict is `CONFIRMED` and the panel is reached through challenges rather than referrals.
   That leaves the REFUTED/UNRESOLVED → panel → `panelOverride` routes unexercised by the
   stateful suite. Worth doing before the circom work, since it shares the fixture.

---

## 7. Reality check on priorities

GLT is a real build with a defensible thesis, but it is **not** the thing with a clock on it.
`~/bounty/SESSION.md` §3 has three unchecked bounty accounts, and identity verification
(§3.2) takes **days to weeks**. That gates the whole income pipeline and gets no cheaper by
waiting. GLT will be in exactly this state in a month either way.

Sequence: do the accounts, then come back here.
