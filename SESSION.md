# SESSION STATE — Galactic-Trust (GLT) / GCIA epistemic ledger
> Re-read this file first every time you resume. This is the single source of truth for GLT.

**Last updated:** 2026-09-30
**Operator:** alexa @ Ubuntu 26.04.1 (WSL2)
**Location:** `~/galactic-trust` (788 src / 1845 test lines Solidity)
**Status:** tri-state evidence gate + bypass, escrow accounting, 93/93 tests green
(4 fuzz suites, verified to 2000 runs), NOT deployed, NOT audited.

---

## 1. Current status

| Item | State |
|---|---|
| Foundry toolchain | ✅ installed at `~/.foundry/bin` (forge 1.5.1) — **needs PATH export, see §3** |
| `GalacticTrust.sol` | ✅ compiles, quorum attestation + challenge window + slashing |
| Test suite | ✅ 93/93 passing (78 unit + 11 adversarial + 4 fuzz) |
| Tri-state evidence gate | ✅ `CONFIRMED`/`REFUTED`/`UNRESOLVED`, enforced at finalize |
| Verifier outage failsafe | ✅ a reverting verifier → `UNRESOLVED`, never a protocol halt |
| Curator quorum snapshot | ✅ snapshotted at submission, owner cannot move it mid-dispute |
| Dispute tie-break | ✅ `expireReview` after `REVIEW_WINDOW` (7 days), rejects by default |
| Commit-reveal gating | ✅ post-window, challenger-or-curator only, verify-and-emit |
| Fuzz/invariant suite | ✅ conservation + multi-challenger payout + expiry terminality |
| Curator stake behind appointment | ❌ weight still owner-assigned and free — see §6 |
| Escrow solvency invariant | ✅ `totalLiabilities()` accounted on every movement |
| Owner burn limited to unbacked balance | ✅ `recoverExcessStake` cannot touch live escrow |
| Challenge bond locked while challenge open | ✅ `lockedChallengeBond` |
| Contract size within EIP-170 | ✅ 19,876 B (was 38,446 B — **undeployable before**) |
| Deploy script | ✅ written, untested against a live RPC |
| Attester bonds + attester slashing | ✅ built and tested |
| Challenge bonds | ✅ built — required to challenge, forfeited if rejected |
| Weighted curator panel | ✅ built — `onlyOwner` ruling replaced |
| Bounded settlement loops | ✅ `MAX_SIGNERS`/`MAX_CHALLENGERS` caps + pull payments |
| Access-gating / query fees (pillar 2) | ❌ not built — separate contract |
| Real ZK verifier | ❌ `IVerifier` is wired and enforced, but no circom verifier exists yet |
| Curator identity/sybil control | ❌ weight is set by owner, no stake behind a curatorship |
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
forge test                        # 93/93
forge test --match-test testFuzz --fuzz-runs 2000
forge build --sizes              # MUST stay under 24,576 B EIP-170
```

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
| optimizer | on, 200 runs |
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
test/Adversarial.t.sol     11 tests, hostile owner / broken verifier / tie / no-challenger
test/Fuzz.t.sol              4 fuzz suites, conservation + terminality
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
submitAttestation()  → PENDING, stake locked in contract, 2-day window opens
  ├─ signAttestation()   ×N attesters, weight accumulates      (capped at MAX_SIGNERS)
  ├─ challengeAttestation() ×N challengers, accumulates       (bond required, capped)
  └─ after window closes:
       ├─ verdict CONFIRMED + quorum + zero challenges
       │      → finalizeAttestation() → stake returned + reward minted
       └─ anything else → curator panel (a REFUTED/UNRESOLVED verdict needs no challenger)
              ├─ quorum reached, non-tied → tallyDispute() → _resolve():
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

### Contract surface (`src/GalacticTrust.sol`, ~300 lines)

| Function | Line | Role |
|---|---|---|
| `fundAttesterBond` | 233 | lock GLT as signing bond |
| `withdrawAttesterBond` | 244 | reclaim bond, only after deactivation |
| `fundChallengeBond` | 289 | lock GLT as challenging bond |
| `withdrawChallengeBond` | 307 | reclaim only the *unlocked* portion |
| `submitAttestation` | 364 | lock stake, open window, returns `id` |
| `signAttestation` | 392 | attester co-sign, accumulates weight |
| `finalizeAttestation` | 408 | **the mint gate** — quorum + window + zero challenges |
| `challengeAttestation` | 427 | red-team flag, accumulates, locks bond |
| `castCuratorVote` | 446 | weighted panel ruling |
| `tallyDispute` | 464 | applies the ruling once curator quorum is met |
| `claimChallengeReward` | 594 | per-challenger pull payment |
| `expireReview` | 543 | forces a stalled dispute after `REVIEW_WINDOW` |
| `checkSecret` | 706 | stateless read-only hash check, records nothing |
| `revealSecret` | 719 | post-window, challenger/curator only, verify-and-emit |
| `evidenceVerdict` | 744 | the machine's tri-state opinion, never reverts |
| `totalLiabilities` | 626 | every token the contract owes, never burnable |
| `excessBalance` | 633 | held minus owed — the only burnable amount |
| `recoverExcessStake` | 641 | burns unbacked balance only |
| `registerAttester` / `deactivateAttester` | 315 / 331 | committee management |

Setters: `setVerifier`, `setQuorumBps`, `setMinStake`, `setRewardAmount`, `setSlashBps`,
`setAttesterBondAmount`, `setAttesterSlashBps`, `setChallengeBondAmount` (all `onlyOwner`;
the challenge setter rejects zero).
Getters: `challengeCount`, `signerWeight`, `attesterBond`, `challengeBond`,
`lockedChallengeBond`, `payoutShare`, `requiredQuorumWeight`, `getAttestation`, `attester`.

> Line numbers drift. Re-derive with
> `grep -nE "^\s+(function|constructor)" src/GalacticTrust.sol` rather than trusting this table.

---

## 5. Hard-won lessons / gotchas

### The 47-green-tests trap (2026-09-30)

The suite was 47/47 and still shipped four fund-loss bugs, because every test exercised
one challenger, one dispute, and a well-behaved owner. **The bugs were all in the N-user
and adversarial-owner cases.** Write the adversarial tests first next time: two challengers,
a hostile owner, an exit mid-dispute. A green suite means the happy path works, nothing more.

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

- **`attestation()` and `getAttestation()` are duplicates** — left in for ergonomics. Collapse
  to one before any external integration.

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
  with `optimizer = true` / `optimizer_runs = 200` → and settlement gas *improved*.
  Now 21,322 B after the tri-state gate (3,254 B margin). `via_ir = true` was measured at
  21,703 B, i.e. 381 B **worse**, so it stays off. **Run `forge build --sizes` as part of the
  build, not just `forge test`** — the test suite passes happily on undeployable bytecode.
  The margin is shrinking with each feature; check it every time.

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

- **Do not append to `~/.bashrc` via a shell heredoc.** The layers between PowerShell,
  `wsl.exe` and `bash` expanded `$PATH` during the append, freezing a ~2 KB absolute PATH
  (including every Windows mount) into the file. Write the line with a literal `\$PATH`, or
  use a heredoc with a quoted delimiter that survives the round trip. Verify with
  `tail -3 ~/.bashrc` and check the line is short.

---

## 6. Next actions, in order

Bugs 4, 5, 7 and 8 were all fixed on 2026-09-30 — see §2 (tri-state gate), §4 (lifecycle),
and §5 (hard-won lessons). What remains:

1. ☐ **Put stake behind a curatorship.** Curator weight is assigned by the owner and costs
   nothing, so the panel is decentralised in *ruling* but not in *appointment*. This is now
   the single largest remaining gap: the tri-state gate routes every REFUTED and UNRESOLVED
   verdict to this panel, so its appointment is now load-bearing for the whole design.
   A curator bond with the same lock-and-slash treatment as `challengeBond` would close it.
2. ☐ **Add a git remote.** History is local-only, so the whole project dies with the laptop —
   the exact failure `~/bounty/SESSION.md` opens with. Still the cheapest high-value item.
3. ☐ **Write a circom verifier** implementing `IVerifier`. The interface is tri-state and the
   gate is live; there is still no real proof system behind it. Until one exists, every
   verdict is `CONFIRMED` and the gate is untested in anger. Model the unsolvable case too:
   a verifier that returns `UNRESOLVED` when a proof is malformed.
4. ☐ **Add an invariant handler**, not just fuzz. Fuzz samples; `invariant_*` runs on every
   state transition reachable in one call. `totalLiabilities() <= balanceOf(address(this))`
   is the one that matters most.
5. ☐ **Collapse the duplicate `attestation()` / `getAttestation()` getters** (still open).
6. ☐ **Reject `deactivateAttester` / `deactivateCurator` on unknown addresses** — they
   silently succeed today, which hides typos in owner scripts.
7. ☐ **Replace the boilerplate `README.md`** (still the Foundry template). It must state
   plainly that GLT asserts *staked testimony*, never truth.
8. ☐ **Test the deploy script against a local Anvil node**, then a testnet. Both bond amounts
   now default non-zero, so the script no longer needs to set them.
9. ☐ **External audit before any mainnet deploy with real value.** Non-negotiable. An
   unaudited contract that mints a token people pay real money for is not a smaller version of
   this one, it is a liability.

---

## 7. Reality check on priorities

GLT is a real build with a defensible thesis, but it is **not** the thing with a clock on it.
`~/bounty/SESSION.md` §3 has three unchecked bounty accounts, and identity verification
(§3.2) takes **days to weeks**. That gates the whole income pipeline and gets no cheaper by
waiting. GLT will be in exactly this state in a month either way.

Sequence: do the accounts, then come back here.
