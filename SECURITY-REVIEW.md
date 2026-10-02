# ENVELOPE — Pre-implementation Security & Design Review

**Scope:** the locked design, before any code existed.
**Verdict: no blocking flaw.**

---

## Method

Adversarial review attacking each party's incentives separately: a dishonest **employer**, a hostile
**claimant**, an outside **observer**, and a confused **user**. Checked the Merkle construction for the
classic pitfalls, the nullifier, claim/reclaim timing, reentrancy, and every public claim the product
makes.

---

## Findings

### F1 — `leafCount` was an unverifiable public claim · MEDIUM · RESOLVED (removed)

The plan carried `leafCount` ("# of commitments") as a public field. **The contract cannot verify it** —
the count is not derivable from a Merkle root. A dishonest employer could publish "10 employees" over a
3-leaf tree and the chain would assert something false.

Since everything we claim must be true and auditable, and this was the *only* unverifiable public value
in the design, **it was removed.** The public view now shows only what the chain can vouch for.

### F2 — The employer can under-fund · HIGH (product, not security) · RESOLVED BY DOCUMENTATION

An employer can commit to salaries summing to more than they fund. Nothing proves
`sum(leaves) <= totalDeposited`. An employee holding a valid proof can have `claim()` revert on
insufficient balance.

**Cannot be prevented** without a sum proof (Pedersen over bn254) — that is ZK, which is out of scope.

**But it cannot be hidden either:**
- Funding is not a promise — the USDG is in the contract and publicly visible.
- `totalClaimed` is monotonic and can never exceed `totalDeposited`.
- An unpaid employee can **demonstrate a valid Merkle proof that reverts for insufficient balance** —
  public, verifiable evidence of non-payment. A dishonest employer leaves a permanent provable
  artefact, not a deniable one.

**The only way for employees to check the aggregate is to collude**, which destroys the privacy the
product exists to provide. That trade-off is the honest description of the design, and the reason
"verifiable payroll totals, private roster" is the strongest claim available.

### F3 — A 1-block deadline could rug recipients · MEDIUM · RESOLVED (rail added)

`reclaim` is deadline-gated, so a very short deadline lets an employer collect commitments and reclaim
almost immediately.

**Fix:** `require(deadline >= block.timestamp + 1 days)`. Consequence: reclaim cannot be shown live
on-chain — it is covered by unit + fork tests instead, which is a better place for it.

### F4 — Loss of salts makes funds unclaimable · MEDIUM (operational) · DOCUMENTED

The employer holds the only copy of the salts. If lost, no employee can build a proof and the money can
only return to the employer via `reclaim` after the deadline — so employees risk **delay, never loss**.
Documented, with an explicit warning before the download step.

### F5 — Merkle construction · VERIFIED SOUND

- **Second-preimage ambiguity:** none. Tagged leaf over 6 words vs `encodePacked` internal node over 2 —
  different domain and length, so an internal node cannot be replayed as a leaf.
- **Leaf binding:** `runId` (cross-run replay), `index` (malleability), `claimant` (entitlement),
  `amount` (bound by proof), `salt` (hides the amount).
- **Front-running a claim:** not profitable — `msg.sender` is bound into the leaf, so a thief holding a
  leaked package can only push funds *to the rightful recipient*.
- **Odd-node handling:** must be pinned or the JS and Solidity trees silently diverge. Chosen: carry the
  odd node up unchanged, never duplicate.

### F6 — Nullifier and timing · VERIFIED SOUND

Nullifier is `(runId, index)`, per-run. `claim` requires `timestamp <= deadline`; `reclaim` requires
`timestamp > deadline`. **The windows do not overlap** → no race, no front-running window.

### F7 — Reentrancy · VERIFIED SOUND

Both value-moving paths are Checks-Effects-Interactions **and** `ReentrancyGuard`-wrapped, with events
emitted before the external call. `claim` is callable only by the recipient, so the recipient is the
only possible re-entrant actor and state is finalised first either way.

### F8 — Accepted risks (documented, no fix)

| Risk | Why accepted |
|---|---|
| `address(this)` not in the leaf | Only the employer creates runs, and reproducing a root requires the salts. No adversarial advantage. |
| A leaf committed with `claimant = address(0)` is unclaimable | Not derivable from a root; the employer UI blocks zero addresses. |
| Tokens sent to the contract by mistake are stuck | Adding rescue means adding admin, and "no admin" is a feature. |
| Amounts are revealed when claimed | Inherent without ZK; documented as a core limitation. |
| Small payrolls leak by deduction | Documented. |

### F9 — Implementation traps flagged for the build

1. `crypto.getRandomValues`, **never** `Math.random` — the latter is not a CSPRNG and would make amounts
   brute-forceable, silently reducing the privacy model to theatre.
2. Sort node pairs by **BigInt**, not hex string — JS string comparison is not byte-order and would
   build a different tree than Solidity verifies. Guarded by a hard-coded parity vector.
3. USDG is **6 decimals** — every conversion goes through one helper.

---

## Result

No blocking flaw. Sound construction, no path to recipient fund loss, no replay, no reentrancy, no race.
The one finding touching the product claim (F2) is resolved by documentation and by the locked framing;
F1 removed the only dishonest public field.
