# Envelope

**Verifiable payroll totals, private roster.**

An employer commits to a payroll as a Merkle root of salted salary commitments and funds the contract
up front. Anyone can then verify **how much was set aside** and **how much has actually been paid out**.
Individual salaries are never published — they exist only as salted hashes, and there is no per-leaf
storage on-chain, so the roster cannot be enumerated by an outside observer.

> **What this is not.** This is *not* fully private payroll, and it does *not* prove that the committed
> salaries add up to the funded total. See [Honest limitations](#honest-limitations) — that boundary is
> the whole design, and we state it rather than paper over it.

Built for the **Arbitrum Open House Singapore Buildathon** (Promising Products track).
Settlement in **Paxos USDG** on **Arbitrum Sepolia**.

---

## The idea

Ordinary on-chain payroll publishes every salary to the world. Ordinary off-chain payroll asks
employees to simply trust the employer. Envelope takes a third position: **the totals are public and
the roster is not.**

- The **root is fixed before any money moves** — the employer cannot alter a committed amount afterwards.
- The **funds are already in the contract** — not a promise.
- The contract pays **exactly** the committed amount to **exactly** the committed address.
- The employer **cannot touch committed funds early** — reclaim is deadline-gated.
- `totalClaimed` can never exceed `totalDeposited`.

## How it works

```
employer                          contract                       employee
   |                                 |                              |
   |-- createRun(root, deadline, --->|  USDG locked                 |
   |        amount)                  |  totalDeposited public       |
   |                                 |                              |
   |                                 |<-- claim(idx, amt, salt, ----|
   |                                 |    proof) if msg.sender      |
   |                                 |    matches the commitment    |
   |                                 |  totalClaimed public --------|
   |                                 |                    USDG paid |
   |-- reclaim() after deadline ---->|  remainder returned          |
```

**Leaf format** (must match byte-for-byte between Solidity and the browser):

```solidity
LEAF_TAG = keccak256("Envelope.PayrollRun.leaf.v1")
leaf = keccak256(abi.encode(LEAF_TAG, runId, index, claimant, amount, salt))
node = sorted-pair keccak256(abi.encodePacked(a, b))
```

An odd node is carried up unchanged (never duplicated). Pairs are sorted by **BigInt**, not by hex
string. Salts come from `crypto.getRandomValues`.

## Honest limitations

These are stated plainly because a judge should be able to check them.

1. **Under-funding is possible.** Nothing proves `sum(leaves) <= totalDeposited`. An employer can commit
   to more than they deposited, and a recipient holding a valid proof can have `claim()` revert on
   insufficient balance. Preventing this needs a sum proof (Pedersen commitments / ZK), which is out of
   scope. **It cannot be hidden, though** — an unpaid recipient can demonstrate a valid Merkle proof
   that reverts, which is public, verifiable evidence of non-payment.
2. **Amounts are revealed when claimed.** The contract must receive `amount` to transfer it, so a claim
   puts that one recipient and amount on-chain.
3. **The aggregate is only checkable by collusion.** Employees can compare their own salaries among
   themselves — which destroys the privacy the product exists to provide. That trade-off is the design.
4. **Small payrolls leak by deduction.** Know the total plus every salary but one, and the last is
   determined. The employer always knows everything.
5. **Missed deadline = lose out.** After the deadline the employer reclaims the remainder and the run
   closes permanently.
6. **Losing the salts delays employees.** They can never build a proof, so funds can only return to the
   employer via `reclaim`. Employees risk delay, never loss.
7. **USDG is not neutral infrastructure.** The settlement token is an upgradeable proxy whose issuer
   retains `paused()` and `isFrozen(address)` control (verified against the live contract — see
   `test/Fork.t.sol`). A frozen recipient cannot claim, a frozen employer cannot `reclaim`, and a paused
   token halts every transfer. This contract cannot defend against the issuer of the money it moves, and
   it does not pretend to.

## Layout

```
src/PayrollRun.sol        the entire on-chain surface — one contract
test/                     unit, fuzz, parity and fork tests
PLAN.md                   locked architecture and implementation plan
SECURITY-REVIEW.md        adversarial review, findings and accepted risks
app/                      static frontend (no backend)
```

## Build & test

```bash
forge build
forge test -vv                                   # unit, fuzz, parity (no network)
forge test --match-contract ForkUSDGTest \
  --fork-url https://sepolia-rollup.arbitrum.io/rpc   # full flow vs the real USDG

node --test test/js/merkle.test.js               # JS tree builder
```

Requires [Foundry](https://book.getfoundry.sh/) and Node ≥ 20. Dependencies (`forge-std`,
`openzeppelin-contracts`) are vendored as git submodules.

## Deployed

| | |
|---|---|
| Chain | Arbitrum Sepolia (421614) |
| `PayrollRun` | _filled in after deployment_ |
| USDG | `0xFFC95faa3d63Cde504a05B567C600B78C0b41892` (6 decimals) |

Contract deployed on an Arbitrum chain, as the Buildathon requires. No factory, no pool, and no token
was created — the product does not need them.

## License

MIT
