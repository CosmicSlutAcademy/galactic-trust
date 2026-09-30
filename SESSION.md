# SESSION STATE — Galactic-Trust (GLT) / GCIA epistemic ledger
> Re-read this file first every time you resume. This is the single source of truth for GLT.

**Last updated:** 2026-09-29
**Operator:** alexa @ Ubuntu 26.04.1 (WSL2)
**Location:** `~/galactic-trust` (~1090 lines Solidity)
**Status:** challenge bonds + curator panel + bounded settlement, 47/47 tests green, NOT deployed, NOT audited

---

## 1. Current status

| Item | State |
|---|---|
| Foundry toolchain | ✅ installed at `~/.foundry/bin` (forge 1.5.1) — **needs PATH export, see §3** |
| `GalacticTrust.sol` | ✅ compiles, quorum attestation + challenge window + slashing |
| Test suite | ✅ 47/47 passing |
| Deploy script | ✅ written, untested against a live RPC |
| Attester bonds + attester slashing | ✅ built and tested |
| Challenge bonds | ✅ built — required to challenge, forfeited if rejected |
| Weighted curator panel | ✅ built — `onlyOwner` ruling replaced |
| Bounded settlement loops | ✅ `MAX_SIGNERS`/`MAX_CHALLENGERS` caps + pull payments |
| Access-gating / query fees (pillar 2) | ❌ not built — separate contract |
| Real ZK verifier | ❌ `IVerifier` hook only, no circom verifier wired |
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

3. **Smart contracts are not legally binding.** No jurisdiction enforces Solidity. The real
   answer is a legal wrapper (Wyoming DAO LLC) + human arbitration for disputes. **Not done.**

**The oracle problem is unsolved, not avoided.** The contract cannot judge whether intel is
*correct*. It can only check that N weighted attesters signed. Trust is therefore bounded and
slashable, not eliminated. This is the honest version of the design.

---

## 3. Running it

```bash
export PATH="$HOME/.foundry/bin:$PATH"   # REQUIRED — foundry is not on PATH by default
cd ~/galactic-trust
forge test          # 47/47
forge build
```

Foundry lives in `~/.foundry/bin`, not `~/.local/bin` (where the recon toolchain is).
Consider appending the export to `~/.bashrc`.

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
| forge-std | 1.16.2 |
| openzeppelin-contracts | 5.7.0 |
| solc | 0.8.33 (auto-installed) |
| evm_version | prague |

**Deploy env vars** (read by `script/Deploy.s.sol`):
`PRIVATE_KEY`, `TREASURY`, `INITIAL_SUPPLY`, `TIMELOCK_DELAY`

---

## 4. Architecture as built

### Lifecycle

```
registerAttester()   → fundAttesterBond()      (bond required before signing)
submitAttestation()  → PENDING, stake locked in contract, 2-day window opens
  ├─ signAttestation()   ×N attesters, weight accumulates      (capped at MAX_SIGNERS)
  ├─ challengeAttestation() ×N challengers, accumulates       (bond required, capped)
  └─ after window closes:
       ├─ zero challenges + quorum → finalizeAttestation() → stake returned + reward minted
       └─ challenges stand → curator panel votes → tallyDispute() once quorum reached
              ├─ uphold majority → _penalise():
              │      submitter stake burned (slashBps)
              │      every signing attester's bond burned
              │      pool = unburned remainder + forfeited challenge bonds
              │      challengers PULL their share via claimChallengeReward()
              └─ reject majority → _forfeitChallengeBonds() burns challengers' bonds,
                                     attestation returns to PENDING and can finalize
```

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
- **Attesters must bond to sign, and cannot withdraw while active.** Prevents bond → certify
  → withdraw before a dispute resolves.
- **Attesters who sign a fabrication lose their bond.** This closes the colluding-quorum hole:
  previously a quorum could certify a lie, the submitter was punished, and the signers were free.
- **Settlement cost is bounded.** `MAX_SIGNERS` / `MAX_CHALLENGERS` (50 each) cap the loops;
  challenger payouts are pull-based so a large challenger set cannot make settlement
  unspendable. `_penalise` remains O(signers).
- Owner is expected to be a `TimelockController` with `admin = address(0)`.
- `Ownable2Step` — `transferOwnership` alone leaves one key in control until accepted.

### Contract surface (`src/GalacticTrust.sol`, ~300 lines)

| Function | Line | Role |
|---|---|---|
| `fundAttesterBond` | 152 | lock GLT as signing bond |
| `withdrawAttesterBond` | 166 | reclaim bond, only after deactivation |
| `submitAttestation` | 250 | lock stake, open window, returns `id` |
| `signAttestation` | 277 | attester co-sign, accumulates weight |
| `finalizeAttestation` | 288 | **the mint gate** — quorum + window + zero challenges |
| `challengeAttestation` | 304 | red-team flag, accumulates |
| `resolveDispute` | 316 | owner ruling, slashes signers or clears |
| `revealSecret` | 335 | recompute hash for a curator |
| `passesVerifier` | 345 | optional ZK hook, true when unset |
| `registerAttester` / `deactivateAttester` | 205 / 221 | committee management |

Setters: `setVerifier`, `setQuorumBps`, `setMinStake`, `setRewardAmount`, `setSlashBps`,
`setAttesterBondAmount`, `setAttesterSlashBps` (all `onlyOwner`).
Getters: `challengeCount`, `signerWeight`, `attesterBond`, `requiredQuorumWeight`,
`getAttestation`, `attester`.

> Line numbers drift. Re-derive with
> `grep -nE "^\s+(function|constructor)" src/GalacticTrust.sol` rather than trusting this table.

---

## 5. Hard-won lessons / gotchas

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

---

## 6. Next actions, in order

1. ☐ **Add a git remote.** History is local-only, so the whole project dies with the laptop —
   the exact failure `~/bounty/SESSION.md` opens with.
2. ☐ **Put stake behind a curatorship.** Curator weight is assigned by the owner and costs
   nothing, so the panel is decentralised in *ruling* but not in *appointment*.
3. ☐ **Build pillar 2**: access-gating + query fees. Separate contract, reads GLT.
4. ☐ Add a **circom verifier** implementing `IVerifier` for real confidential evidence.
5. ☐ **Invariant + fuzz tests.** Cap the signer/challenger arrays, and fuzz `_penalise` for
   conservation of GLT (tokens in == burned + escrowed + returned).
6. ☐ Replace the boilerplate `README.md` (still the Foundry template).
7. ☐ Test deploy script against a local Anvil node, then a testnet.
8. ☐ External audit **before** any mainnet deploy with real value.

---

## 7. Reality check on priorities

GLT is a real build with a defensible thesis, but it is **not** the thing with a clock on it.
`~/bounty/SESSION.md` §3 has three unchecked bounty accounts, and identity verification
(§3.2) takes **days to weeks**. That gates the whole income pipeline and gets no cheaper by
waiting. GLT will be in exactly this state in a month either way.

Sequence: do the accounts, then come back here.
