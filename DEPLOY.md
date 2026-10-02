# Deployment parameters — frozen

**Status: NOT DEPLOYED.** This file specifies the exact deployment so it can be executed deliberately.
Nothing here has been broadcast, and no signature has been requested.

## Frozen revision

| | |
|---|---|
| Commit | `050a4070123d4855f96fbc29b090f4af0cac8ba0` |
| Branch | `master` |
| Repo | https://github.com/Zaygal/envelope |
| Flattened source | `deploy/PayrollRun.flat.sol` (1,517 lines) |
| Creation code | 3,923 bytes (limit 24,576 — ample headroom) |
| Compiler | solc 0.8.24, optimizer on, 200 runs |

Build the artifact yourself rather than trusting this table:

```bash
forge flatten src/PayrollRun.sol > deploy/PayrollRun.flat.sol
forge build --sizes
```

## Parameters

| Field | Value |
|---|---|
| **Chain ID** | **421614** (Arbitrum Sepolia) |
| **RPC** | `https://sepolia-rollup.arbitrum.io/rpc` |
| **Constructor argument** | `USDG = 0xFFC95faa3d63Cde504a05B567C600B78C0b41892` |
| **Constructor args, ABI-encoded** | `000000000000000000000000ffc95faa3d63cde504a05b567c600b78c0b41892` |
| **Value sent** | `0` (no ETH) |
| **Contract** | `PayrollRun` — constructor takes the settlement token address |

The constructor argument is **one address** and nothing else. There is no owner argument, no admin
argument, no fee recipient, and no upgrade hook.

## Deployment command

```bash
forge create src/PayrollRun.sol:PayrollRun \
  --rpc-url https://sepolia-rollup.arbitrum.io/rpc \
  --constructor-args 0xFFC95faa3d63Cde504a05B567C600B78C0b41892
```

That broadcasts a transaction that spends **testnet ETH for gas only**. It moves no USDG: the token is
pulled in later, per run, by `createRun`.

## Wallet model

Three things stay strictly separate:

1. **Connection** — the agent may propose a transaction.
2. **Signing** — only you, on your own device.
3. **Key custody** — never the agent. No seed phrase or private key is requested, and none should be
   pasted into code, chat, or an agent.

So the deployment is executed by you, from your own device, against the parameters above. A dedicated
buildathon wallet is preferable to a personal one.

## Before signing, confirm

- the signing device is on chain **421614** (a MetaMask prompt showing any other network is wrong)
- the transaction sends **0** value
- the only calldata payload is the constructor argument above
- the recipient of the deployment is a contract you expect

## After deployment

1. Record the `PayrollRun` address and confirm `usdg()` returns
   `0xFFC95faa3d63Cde504a05B567C600B78C0b41892`.
2. Fill the address into `README.md` (the `Deployed` table) and the frontend's default contract field.
3. Fund a run: get testnet USDG from the Paxos faucet, then `approve` + `createRun` in the employer view.
4. Confirm the frontend loads the run with no wallet connected — the public proof view is the demo.

No mainnet deployment, and no mainnet approval, is part of this buildathon submission.
