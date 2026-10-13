# GLT — legal-wrapper plan

> **Not legal advice.** This is an engineering planning document written by a non-lawyer. It
> records *what needs legal input*, not *what the law says*. Retain qualified counsel in the
> relevant jurisdiction before formation, before any public token distribution, and before the
> contract holds anything of value on a public network.

This is the §6.6 companion to `AUDIT.md`. The code audit asks "is the contract correct?"; this
track asks "is there a legal person behind it, and what can anyone enforce?" They are independent.

## 1. Why a wrapper is needed at all

`SESSION.md` §2 item 3: **smart contracts are not legally binding.** No jurisdiction enforces
Solidity. An on-chain ruling moves tokens; it does not create an obligation a court can enforce,
and it cannot adjudicate the thing the token is actually about — whether a claim is true. The
contract says so explicitly: it asserts a *stake*, not a fact.

Two gaps a wrapper has to close:

1. **Enforceability.** A curator or attester slashed on-chain has no contractual duty to accept
   the ruling or to fund a shortfall. Conversely, a submitter whose stake is withheld has no
   cause of action against the protocol. A legal person with a membership agreement gives the
   ruling a party to bind.
2. **Real-world recourse.** Disputes that turn on truth — defamation, misrepresentation, fraud,
   breach of confidence — have no on-chain remedy. Human arbitration is the binding layer; the
   chain is the *record*. The design already assumes this (it never claims truth), so the wrapper
   is where the missing half lives.

## 2. What the wrapper must hold and govern

- **The treasury.** The initial supply is minted to `TREASURY`, and the owner is intended to be a
  `TimelockController` with `admin = address(0)`. The entity must control the treasury key(s) and
  the timelock's proposer set, with documented signer duties and custody.
- **The governor role.** Whoever holds the (timelocked) owner key appoints attesters and curators
  and sets bond/quorum/slash parameters. That is real power over a real process and belongs to a
  named entity, not an anonymous key.
- **Members.** Attesters, curators, and challengers are participants in a bonded process. Their
  rights and duties — how to become one, what a slash means, how to exit — should be written, not
  merely implied by the contract.
- **The dispute layer.** A human arbitration clause covering off-chain truth disputes, and how a
  legal outcome maps back to on-chain state (if at all — it may not, and that is acceptable).

## 3. Candidate structures

The right choice turns on whether token holders are expected to profit — a securities-analysis
question for counsel, not for this document.

- **Wyoming DAO LLC** — Wyoming's 2021 DAO Supplement to its LLC Act. An LLC that can be
  member- or algorithm-managed, with statutory recognition of on-chain governance and limited
  liability for members. Name must contain "DAO LLC"; a registered agent is required. The
  conventional for-profit choice.
- **Wyoming DUNA** — Decentralized Unincorporated Nonprofit Association (2024). Nonprofit, no
  members' profit interest, built for protocol governance bodies. Appropriate only if the token
  confers no expectation of profit.
- **A conventional LLC or foundation + a membership agreement**, if the DAO-specific statutes add
  cost without solving a real problem.

The `SESSION.md` §2.3 note assumes the DAO LLC; that is a placeholder, not a decision.

## 4. Open questions for counsel

1. **Token characterization.** Is GLT an investment contract under *Howey* and applicable state
   law? Does "you stake and may earn a reward from a settlement" create an expectation of profit
   from others' efforts? This drives the structure choice and whether a public distribution is
   possible at all.
2. **Slashing as liquidated damages.** On-chain slashing of a bond is, in substance, a penalty.
   Is it enforceable as liquidated damages rather than an unenforceable penalty? Does the
   membership agreement need to recite the parties' agreement to it?
3. **Liability shield.** Do members, curators, and attesters get limited liability for rulings
   made in good faith, and what happens to personal liability for a malicious ruling?
4. **Tax.** Minted rewards, slashed bonds, and forfeited challenge bonds all have tax
   consequences for the participants and the entity.
5. **Money transmission.** If GLT is used to move value between parties, does the operator fall
   under MSB / money-transmitter rules?
6. **Privacy / data protection.** Attestations use commit-reveal (`contentHash` + `secret`), but a
   reveal publishes the pre-image and the record may contain personal or commercially sensitive
   intelligence. If the operator is a controller under GDPR/CCPA, what obligations attach to the
   records and to any off-chain artifacts?
7. **Custody and key management.** How the entity holds the treasury and timelock keys, signer
   duties, succession, and what happens on the loss of a key.

## 5. Decision checklist

- [ ] Engage counsel (crypto/DAO-experienced, in the chosen jurisdiction).
- [ ] Obtain a token-characterization memo **before** any public distribution.
- [ ] Choose the structure based on that memo (for-profit DAO LLC vs nonprofit DUNA vs LLC).
- [ ] Draft the membership/operator agreement, including a human-arbitration clause and the
      slashing-as-liquidated-damages recital.
- [ ] Map the treasury and `TimelockController` custody to the entity; document signers.
- [ ] Privacy review of attestation contents and any published reasoning artifacts.
- [ ] Confirm the deploy/bring-up runbook hands the owner role to the timelock
      (`script/Deploy.s.sol`, `README.md` "Bringing a deployment up").

## 6. Explicitly out of scope

- **Off-grid settlement.** Physically impossible as specified (`SESSION.md` §2.1); a legal wrapper
  does not change that.
- **Making on-chain rulings legally binding.** They are not, and this plan does not pretend
  otherwise — arbitration is the binding layer.
- **The token-boundary secret check.** Decided against on 2026-10-12 (`SESSION.md` §6.5); an
  integrator-side concern, not a legal one.
- **The code audit.** Separate track; see `AUDIT.md`.
