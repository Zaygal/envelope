/**
 * Emits a deterministic roster + root for the local end-to-end frontend check.
 *
 * Uses the same app/lib/merkle.js the browser uses, so what the local chain stores is exactly
 * what the frontend will read and what a claim package will contain.
 *
 * Run: node scripts/local-demo.mjs
 */

import { buildRoster, claimPackage, USDG_DECIMALS } from '../app/lib/merkle.js';

// anvil's well-known funded accounts — local only, never used for anything real
const ALICE = '0x70997970C51812dc3A010C7d01b50e0d17dc79C8';
const BOB = '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC';
const CAROL = '0x90F79bf6EB2c4f870365E785982E1f101E93b906';

const RUN_ID = 1n;

const { root, total, totalHuman, entries } = buildRoster(
  [
    { address: ALICE, amount: '900' },
    { address: BOB, amount: '400' },
    { address: CAROL, amount: '200' },
  ],
  RUN_ID,
);

const deadline = BigInt(Math.floor(Date.now() / 1000) + 30 * 86400);

// machine-readable line for the shell driver
console.log(`ROOT=${root}`);
console.log(`TOTAL=${total}`);
console.log(`TOTAL_HUMAN=${totalHuman}`);
console.log(`DEADLINE=${deadline}`);
console.log(`DECIMALS=${USDG_DECIMALS}`);

// and the packages, for the claim check
entries.forEach((e) => {
  const pkg = claimPackage({
    runId: RUN_ID,
    contract: process.env.PAYROLL_ADDR || '0x0000000000000000000000000000000000000000',
    entry: e,
  });
  console.log(`PKG_${e.index}=${JSON.stringify(pkg)}`);
});
