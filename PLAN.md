# ENVELOPE — Locked Architecture & Implementation Plan

**Verifiable payroll totals, private roster.**

The canonical one-line claim, and the only one we make. Deliberately **not** "verifiable payroll"
(which would imply a third party can independently verify the entire salary allocation — they cannot,
and the contract does not prove it).

---

## 0. Verified facts (first-hand)

| Fact | Value | How verified |
|---|---|---|
| Network | Arbitrum Sepolia, chainId **421614** | RPC |
| USDG address | `0xFFC95faa3d63Cde504a05B567C600B78C0b41892` | `eth_call` + **Paxos docs list the same address** |
| USDG name / symbol | `Global Dollar` / `USDG` | `eth_call` |
| USDG decimals | **6** | `eth_call` |
| USDG supply | 2,111,011.00 USDG | `eth_call` |
| EIP-2612 permit | available (`DOMAIN_SEPARATOR()` + `nonces(address)` respond) | `eth_call` |
| Faucet | `https://faucet.paxos.com/` live (HTTP 200) | fetch |
| Rulebook: chain | *"Your project must be deployed on an Arbitrum chain to qualify. For example: Arbitrum Sepolia, Arbitrum One, Robinhood Chain, or others."* (both tracks) | live HackQuest page |
| Rulebook: USDG | *"Extra consideration is given to projects integrating Paxos' USDG stablecoin."* | live HackQuest page |
| Rulebook: milestones | *"All prizes are subject to development-tied milestones."* | live HackQuest page |

**Cost of the demo: $0.** All assets are testnet-only and valueless.

---

## 1. Contract design — `src/PayrollRun.sol`

One contract. **No factory** (no CREATE), no token, no pool, no proxy. Multiple runs live inside the
one contract keyed by `runId`, so the employer view has history and `reclaim` is per-run, while the
deploy stays **one transaction**.

```solidity
struct Run {
    address employer;
    bytes32 root;           // Merkle root of salted commitments
    uint64  deadline;       // claims open until here; after this only reclaim
    uint256 totalDeposited; // USDG actually funded  (public)
    uint256 totalClaimed;   // USDG actually paid out (public)
    bool    reclaimed;
}
```

| Function | Who | Effect |
|---|---|---|
| `createRun(root, deadline, amount)` | employer | `transferFrom` amount in, store run, emit |
| `claim(runId, index, amount, salt, proof)` | the committed address only | verify, mark claimed, `totalClaimed += amount`, transfer |
| `reclaim(runId)` | employer, after deadline | return remainder, close run |
| `runs(runId)` / `remaining(runId)` / `runCount()` | anyone | public reads |
| `leafFor(...)` / `verifyClaim(...)` | anyone | check a proof without spending gas |

The claimant is `msg.sender`, so it is bound into the leaf — **a leaked claim package can only ever
push funds to the rightful recipient, never to a thief.**

Safety: OpenZeppelin `MerkleProof` + `ReentrancyGuard`, Checks-Effects-Interactions, solc 0.8.24.
**No admin, no owner, no pause, no upgrade, no fee, no mint** — nothing to trust after deploy.

`MIN_DEADLINE = 1 days` blocks a 1-block "rug" deadline.

**Documented limitation:** after the deadline the employer reclaims *all* unclaimed funds and the run
closes — a recipient who misses the deadline loses out. The v2 fix (extension, per-recipient
deadlines, notifications) is noted, not built.

---

## 2. Privacy model (exact)

**HIDDEN — the roster.** Amounts are salted commitments; there is no per-leaf storage on-chain, so
nothing can be enumerated or scanned. The roster is not derivable from the root.

**PUBLIC — the money.** Employer, root, `totalDeposited`, `totalClaimed`, deadline, and each claim
(recipient + amount) once claimed.

**REVEALED AT CLAIM:** that one claimant's address and amount. Unavoidable without ZK — the contract
must receive `amount` to transfer it.

**WHAT WE CANNOT PROVE:** an outsider **cannot** verify that the committed amounts sum to
`totalDeposited`. You can verify the money was really set aside and really paid out, but not that the
leaves sum to the total. Proving it needs Pedersen commitments or ZK — explicitly out of scope.

**What still holds, and is the real product:**
1. The root is **fixed before any money moves** — the employer cannot alter anyone's amount afterwards.
2. The funds are **already in the contract**, not a promise.
3. The contract pays **exactly** the committed amount to **exactly** the committed address.
4. The employer **cannot** touch committed funds early — reclaim is deadline-gated.
5. `totalClaimed` can never exceed `totalDeposited`; both are on-chain facts.

**Named weaknesses:**
- **Under-funding is possible and not preventable**, but it is *provable*: an unpaid recipient can
  demonstrate a valid Merkle proof that reverts for insufficient balance — public, verifiable evidence
  of non-payment, which a dishonest employer cannot deny or erase.
- The only way for employees to check the aggregate is to **collude** — comparing their own salaries —
  which destroys the privacy the product exists to provide. That trade-off *is* the design.
- Small payrolls leak by deduction; the employer knows everything; reusing a recipient set across runs
  allows linkage.

---

## 3. Merkle leaf format

```solidity
bytes32 constant LEAF_TAG = keccak256("Envelope.PayrollRun.leaf.v1");
leaf = keccak256(abi.encode(LEAF_TAG, runId, index, claimant, amount, salt));
node = a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a)); // OZ convention
```

- `runId` inside the leaf → kills cross-run replay.
- `index` inside the leaf → kills index malleability.
- `claimant` inside the leaf → entitlement bound to one address.
- `amount` in USDG **6-decimal** base units; `salt` = 32 bytes from `crypto.getRandomValues`.
- `abi.encode` for the leaf (no ambiguity); distinct domain from internal nodes → no second-preimage.

**Tree rule:** an odd node is **carried up unchanged, not duplicated** (duplication invites the classic
duplicate-node weakness).

**Implementation traps:** sort node pairs by **BigInt**, never by comparing hex strings; use
`crypto.getRandomValues`, never `Math.random` (which would make amounts brute-forceable and reduce the
privacy model to theatre).

---

## 4. Claim / reclaim mechanics

`claim` checks: run exists → not reclaimed → `block.timestamp <= deadline` → `!leafClaimed[runId][index]`
→ proof verifies. Then effects, then transfer. Nullifier = `(runId, index)`.

`reclaim` checks: caller is the employer → `block.timestamp > deadline` → not already reclaimed.

The claim window and the reclaim window **do not overlap**, so there is no race to front-run.

---

## 5. Frontend

Static single-page app, **no backend**, ethers v6 via ESM CDN.

- **Employer view** — connect (chain guard 421614), add `(address, amount)` rows, CSPRNG salt per row,
  build the tree, download one claim package per recipient, then Approve → Create run.
- **Claim view** — paste/drop a package, verify locally, "You are entitled to X USDG", then Claim.
- **Public proof view — needs no wallet at all.** Employer, root, `totalDeposited`, `totalClaimed`,
  remaining, deadline, and: *"Individual amounts are not published. Only the total is public."*

---

## 6. Test plan

Unit tests vs a 6-decimal mock USDG, plus a **fork test against the real USDG**.

1. `createRun` semantics + reverts (zero root, zero amount, deadline too soon, insufficient allowance)
2. `claim` happy path
3. `claim` reverts: bad proof, wrong index, wrong amount, wrong claimant, double claim, unknown run,
   after deadline, after reclaim
4. `reclaim`: auth, timing, remainder, closes claims, no double reclaim
5. Invariants/fuzz: `totalClaimed <= totalDeposited`; `balance == totalDeposited - totalClaimed`
6. Full-tree fuzz: N random recipients all claim, sum matches exactly
7. **Leaf parity**: browser-generated `(leaf, root, proof)` verified on-chain
8. Privacy regression: no per-leaf data readable before claim
9. Fork test: approve → createRun → claim → reclaim against real USDG

---

## 7. Deployment & the only signatures you make

All on **chainId 421614**, all valueless:

1. **Deploy** `PayrollRun(0xFFC95faa3d63Cde504a05B567C600B78C0b41892)`
2. **Approve** USDG to the contract
3. **`createRun(root, deadline, amount)`**
4. **`claim(...)`** from a recipient address

Funding: ~0.01 testnet ETH for gas; USDG works with **any amount ≥ ~3 USDG** (figures are cosmetic).
Default proposal: 3 recipients totalling 1,500 USDG.

Custody: the agent never needs a key, seed, or signing rights — only the deployed address and tx
hashes, both public.

---

## 8. Demo (~75s)

1. Public view of a run: totals visible, three salaries hidden.
2. Employer view: the roster appears *only for the employer*.
3. Employee view: "You are entitled to 900.00 USDG in run #1."
4. Claim — a real signature.
5. Public view: `totalClaimed` jumps, that one amount becomes visible, **the other two stay hidden.**

Close: *"Everyone can see the company set aside 1,500 and paid out 900. Nobody can see the other two
salaries."*

---

## 9. Cut deliberately

backend · factory · token · auth · notifications · mainnet · second chain · ZK/FHE ·
admin/pause/upgrade · fee · anything that only makes the submission look bigger.
