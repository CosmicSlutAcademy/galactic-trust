# GLT — auditor hand-off brief

**Subject:** `src/GalacticTrust.sol` (single contract, 1,007 lines) + `src/IVerifier.sol`.
**Status:** unaudited. No mainnet deploy with real value. A throwaway-key Sepolia deployment
exists to exercise the mechanics only — it holds nothing of worth.

This is the package an external auditor should start from. It is not a substitute for the
audit; it is the map. The sections are ordered by yield: the history first, because the *class*
of error in this contract is systematic, and the history is the best evidence of where the next
one is. `SESSION.md` §5 is the long form of everything below.

---

## 1. What the contract claims — read this before judging any design choice

An ERC-20 whose supply is released by a staked, bonded, disputable attestation process.

> GLT asserts that these weighted parties staked these amounts on this claim, and that this is
> the dispute record. **It does not assert that the claim is true.**

The oracle problem is bounded and slashable here, not solved. Adding truth-adjacent semantics is
out of scope by design. Three original pillars were impossible as specified and their substitutes
are deliberate (`SESSION.md` §2): off-grid LoRaWAN settlement, "ZK proves truth", and legally
binding smart contracts.

## 2. Trust model / assumptions worth attacking

- **Owner is expected to be a `TimelockController` with `admin = address(0)`.** Until it is,
  the owner is one key. The owner appoints attesters and curators and sets weight: the panel
  decentralises the *ruling*, not the *appointment*. A hostile-owner test exists
  (`test_HostileOwnerCannotFreezeOrSteal`); try to break it.
- **Quorum is snapshotted at submission** for attesters (`att.quorumWeight`) and curators
  (`att.curatorQuorumWeight`). Reading either live let the owner appoint a whale mid-dispute and
  freeze the dispute permanently — fixed, but re-derive both snapshot points yourself.
- **Tri-state verdict.** `CONFIRMED` / `REFUTED` / `UNRESOLVED`. A **reverting** verifier maps to
  `UNRESOLVED`; **no verifier set** means `CONFIRMED`. The failsafe is that an outage can never
  halt the protocol. A boolean gate would collapse "proof says false" and "proof is broken" into
  one value — that is how an outage becomes a silent mint or a total freeze.
- **No probabilistic judge on the mint path**, deliberately (§2). A contract cannot compute a
  probability; flattening it to a scalar destroys the uncertainty that motivated it.
- **`CircomVerifier` (3,816 B) is a separate contract.** Out of scope for this audit except for
  its **trust boundary**: the device registry (`approvedDevice`) is the real anchor, and
  `deviceKeyHash` must be bound to the signing key *inside the circuit*. Some of its properties
  are not observable from Solidity at all — see §5 "The verifier's trust boundary".

## 3. The six failure modes this codebase is most prone to

Every real bug found to date fits one of these (`AGENTS.md`). They double as a hunting list.

1. **A per-record field not cleared where its twin is cleared.** `_penalise` clears `att.stake`;
   `finalizeAttestation` once did not, and all 105 tests passed. Solvency read the already-correct
   aggregate, so no invariant saw it. Diff every settlement path against the others and check the
   *record*, not just the arithmetic.
2. **A per-participant record cleared while its aggregate is not.** Clearing `curatorBallot[id][c]`
   let a curator stack a second vote onto a decided tally, because `upholdWeight` / `rejectWeight`
   are never reset.
3. **A bond withdrawable before the slash.** A bond is real only if
   bond → rule → deactivate → withdraw is closed. `curatorOpenVotes` and `lockedChallengeBond`
   exist for this.
4. **A live read where a snapshot was required.** See quorum above.
5. **A vacuous property.** A property the code already enforces cannot fail. Two properties
   written to catch the 2026-10-05 bugs were green while testing nothing, and the 2026-10-12 fuzz
   fixture had `quorumWeight == 0` so its terminality claim never touched the quorum axis.
   **To confirm a property is real, break the code it describes and watch it go red**
   (`script/vacuity-check.sh`).
6. **A property of the circuit checked only from the contract.** Cannot be tested on-chain; see
   §2 and §5 of `SESSION.md`.

## 4. Every fund-loss bug found and fixed to date

| Date | Root cause | Fix | Guard / where |
|---|---|---|---|
| 09-30 | First caller drained the whole challenge payout pool (`hasClaimed` on a transient list) | persistent `wasChallenger` | `test_RevertWhen_NonChallengerClaims` |
| 09-30 | A rejected dispute stranded the challenger's bond (never returned or slashed) | `_forfeitChallengeBonds` | adversarial |
| 09-30 | One `onlyOwner` curator could slash honest attesters | weighted panel + quorum + non-tie | `castCuratorVote` / `tallyDispute` |
| 09-30 | A colluding quorum was free — attesters who certified a lie lost nothing | per-attester bonds + slashing leg in `_penalise` | `testFuzz_...` |
| 09-30 | One challenger could freeze any attestation | challenges accumulate; escalation is curator-quorum | `test_ChallengeDoesNotFreezeSignatures` |
| 09-30 | `payoutPool` could not represent N independent claims | per-challenger `payoutShare[id][addr]`, pull payments | multi-challenger payout fuzz |
| 09-30 | `recoverExcessStake` was an owner rug on live escrow | `totalLiabilities()` / `excessBalance()` | `_assertSolvent()` everywhere |
| 09-30 | Challenge bonds withdrawable mid-challenge | `lockedChallengeBond` + `_releaseLock` at settlement | adversarial |
| 09-30 | Bond defaults were `0` — free signing and challenging | non-zero defaults; setters reject `0` | deploy check |
| 09-30 | `totalStaked` lost only the burned leg on `_penalise` (book insolvent, balance fine) | subtract the whole stake | `testFuzz_SettlementConservesTokens` |
| 09-30 | Could not deploy — 38,446 B runtime, optimizer off | `optimizer = true`; `--sizes` in the build | `forge build --sizes` |
| 10-02 | Curatorship had no skin; a curator could exit before a slash | `fundCuratorBond` + `curatorOpenVotes` | curator-bond tests |
| 10-05 | `expireReview`'s default-reject + ties recorded a human overruling that never happened | require `rejectWeight > upholdWeight` | referral-path tests |
| 10-05 | A panel could be re-opened after it had ruled (referral path) | `panelSettled[id]` | `test_NoCuratorMayVoteAfterThePanelHasRuled` |
| 10-05 | An uphold left `panelOverride` on a `SLASHED` attestation | clear it on uphold | invariant |
| 10-08 | A forfeited bond was the challenger's **whole balance**, not the pledge | use `challengeLock[id][c]` in both legs | vacuity entries A, B |
| 10-08 | A **sub-quorum** panel could overrule the machine | gate the override on `curatorQuorumWeight` | vacuity entry C |
| 10-08 | A stalled `UNRESOLVED` attestation held `minStake` with no exit | `EXPIRED` terminal state; `_resolve` releases | vacuity entry E |
| 10-12 | A panel override (or a `CONFIRMED` verdict) with **no attester quorum** stranded the stake | gate the override on attester quorum; release on under-quorum | vacuity entries F, G |

Also: `_resolve` must set `panelOverride` **before** clearing the challenger list, or an
attestation deadlocks permanently (the order is conditional on the current verdict).

## 5. Explicit questions for the auditor

1. **The `expireReview` default-reject path.** Can any *other* `panelOverride` + `panelSettled`
   combination still deadlock funds? The attester-quorum one was closed 2026-10-12 (§5 "The
   attester-quorum terminality gap"); assume there are more and look for the general shape.
2. **`ERC20Votes` checkpoints vs `_burn` during settlement.** Does burning stakes and slashed
   bonds during settlement interact badly with the checkpoint machinery or delegation?
3. **Account aggregate where a per-record figure is owed.** The 2026-10-08 forfeit bug was exactly
   this, it survived 155 green tests and 10 green invariants, and it is the single strongest
   argument for reading §5: the class is systematic.
4. **The accepted minor, deliberately left in.** `expireReview` omits the `NoChallengesToResolve`
   guard that `castCuratorVote` and `tallyDispute` both have, so on a `CONFIRMED` *unchallenged*
   attestation it runs to completion and emits `ReviewExpired` on a record nobody disputed,
   setting `panelSettled` on the way through. **No funds move** and the attestation still
   finalizes with its reward — a false event, not a loss. Pinned in
   `test_ConfirmedAttestationIsUnaffected`. A guard costs margin that has not been allocated.
5. **Governance wiring before mainnet.** The owner must be a `TimelockController` with
   `admin = address(0)`, and `registerCurator` / `registerAttester` are `onlyOwner` — so the panel
   is reachable **only** through the timelock. This path fails *silently* if bonds are unfunded
   (see `script/Deploy.s.sol:Verify`).

## 6. Invariants to check independently

- **Solvency: `balanceOf(address(this)) >= totalLiabilities()`** — "held ≥ owed", not "the
  arithmetic balances". Every token movement must maintain `totalLiabilities()`.
- **Conservation across settlement** (`testFuzz_SettlementConservesTokens`): no path mints
  outside the gate or loses a token between stake, bonds, and payouts.
- **Terminality:** every terminal state (`FINALIZED` / `SLASHED` / `EXPIRED`) retains no live
  stake, and a post-expiry `PENDING` must be able to reach `FINALIZED`.
- **Override provenance:** an override only ever comes from a strict, quorum-met reject majority,
  and never survives onto a `SLASHED` attestation.
- Read the invariant handler **revert column**, not the suite result: `reverts ≈ calls` means an
  operation is failing on every invocation while the suite stays green.

## 7. Reproduce

```bash
cd ~/galactic-trust
/home/alexa/.foundry/bin/forge test                          # 168/168, ~5 s
FOUNDRY_PROFILE=deep /home/alexa/.foundry/bin/forge test     # ~200 s (2000 fuzz × 5, 128k invariant calls)
/home/alexa/.foundry/bin/forge build --sizes                 # GalacticTrust 23,234 B / 24,576 B EIP-170
bash script/vacuity-check.sh                                 # reverts each fix; every one must go red
bash script/pre-ship.sh                                      # deep profile + handler revert column
```

Use the **absolute** `forge` path: bare `forge` can resolve to ZOE, an unrelated 2013 binary
(`SESSION.md` §3).

**Measured state at hand-off:** 168 tests, `GalacticTrust` 23,234 B (1,342 B of EIP-170 margin),
`CircomVerifier` 3,816 B, invariant handler 0 reverts / 1,280,000 calls.

## 8. What this brief does *not* cover

- The verifier's internal proof-system soundness (only its Solidity-side trust boundary).
- Off-grid settlement, which is physically impossible as originally specified (§2.1).
- Economics / tokenomics and governance design — out of scope for a code audit.
- Legal enforceability, which is the separate `LEGAL.md` track.
