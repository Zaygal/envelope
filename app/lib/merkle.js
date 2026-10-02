/**
 * Envelope — client-side commitment tooling.
 *
 * This module is the ONLY place the tree is built. It must produce byte-for-byte identical
 * hashes to `PayrollRun.sol`, which is enforced by `test/Parity.t.sol` (Sol ↔ JS parity).
 *
 * Runs unchanged in the browser and in Node (Web Crypto is available in both).
 */

import { AbiCoder, concat, keccak256, parseUnits, toUtf8Bytes } from 'ethers';

/** Must equal `keccak256("Envelope.PayrollRun.leaf.v1")` in the contract. */
export const LEAF_TAG = keccak256(toUtf8Bytes('Envelope.PayrollRun.leaf.v1'));

/** USDG uses 6 decimals on Arbitrum Sepolia. Verified on-chain. */
export const USDG_DECIMALS = 6;

export const ARBITRUM_SEPOLIA_CHAIN_ID = 421614;

export const USDG_ARBITRUM_SEPOLIA = '0xFFC95faa3d63Cde504a05B567C600B78C0b41892';

const coder = AbiCoder.defaultAbiCoder();

/**
 * Canonical leaf hash. Mirrors `PayrollRun.leafFor` exactly.
 *
 * Uses `abi.encode` (each argument padded to 32 bytes), NOT `encodePacked` — so adjacent
 * fields can never be ambiguous, and the leaf shares no preimage domain with an internal node.
 */
export function hashLeaf(runId, index, claimant, amount, salt) {
  return keccak256(
    coder.encode(
      ['bytes32', 'uint256', 'uint256', 'address', 'uint256', 'bytes32'],
      [LEAF_TAG, runId, index, claimant, amount, salt],
    ),
  );
}

/**
 * Internal node hash: `abi.encodePacked(sorted(a, b))`.
 *
 * CRITICAL: the comparison is done as BigInt. Comparing the hex strings directly would use
 * lexicographic order, which is NOT byte order, and would silently build a different tree
 * than Solidity verifies.
 */
export function hashPair(a, b) {
  const [x, y] = BigInt(a) <= BigInt(b) ? [a, b] : [b, a];
  return keccak256(concat([x, y]));
}

/**
 * Build the Merkle tree.
 *
 * Odd-node rule: when a level has an odd count, the final node is CARRIED UP UNCHANGED.
 * It is never duplicated — duplication is the classic source of the duplicate-node weakness.
 * This must match `_buildTree` in the Solidity tests and the contract's verifier.
 *
 * @param {string[]} leaves 32-byte hex leaf hashes
 * @returns {{root: string, proofs: string[][], depth: number}}
 */
export function buildTree(leaves) {
  if (!Array.isArray(leaves) || leaves.length === 0) {
    throw new Error('buildTree: needs at least one leaf');
  }

  const levels = [leaves];
  let depth = 0;

  while (levels[depth].length > 1) {
    const cur = levels[depth];
    const next = [];
    for (let i = 0; i < cur.length; i += 2) {
      if (i + 1 === cur.length) {
        next.push(cur[i]); // carried up unchanged
      } else {
        next.push(hashPair(cur[i], cur[i + 1]));
      }
    }
    levels.push(next);
    depth++;
  }

  const proofs = leaves.map((_, i) => {
    const proof = [];
    let idx = i;
    for (let lvl = 0; lvl < depth; lvl++) {
      const len = levels[lvl].length;
      if (idx % 2 === 1) {
        proof.push(levels[lvl][idx - 1]); // left sibling
      } else if (idx + 1 < len) {
        proof.push(levels[lvl][idx + 1]); // right sibling
      }
      // otherwise this node was carried up: it contributes no proof element
      idx = Math.floor(idx / 2);
    }
    return proof;
  });

  return { root: levels[depth][0], proofs, depth };
}

/**
 * 32 bytes of cryptographically secure randomness.
 *
 * SECURITY: `crypto.getRandomValues` only. `Math.random` is not a CSPRNG — using it would make
 * salaries brute-forceable and reduce the privacy model to theatre.
 */
export function randomSalt() {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return '0x' + Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
}

/** Convert a human USDG amount ("900", "1234.56") to 6-decimal base units. */
export function toUnits(human) {
  return parseUnits(String(human), USDG_DECIMALS);
}

/** Convert 6-decimal base units back to a human USDG string. */
export function fromUnits(units) {
  const s = BigInt(units).toString().padStart(USDG_DECIMALS + 1, '0');
  const whole = s.slice(0, -USDG_DECIMALS);
  const frac = s.slice(-USDG_DECIMALS).replace(/0+$/, '');
  return frac ? `${whole}.${frac}` : whole;
}

/**
 * Turn a roster into a funded, commit-ready payroll.
 *
 * @param {{address: string, amount: string|bigint}[]} roster
 * @param {number|bigint} runId
 * @returns {{root: string, total: bigint, totalHuman: string, entries: object[]}}
 */
export function buildRoster(roster, runId) {
  if (!Array.isArray(roster) || roster.length === 0) {
    throw new Error('buildRoster: roster is empty');
  }

  const entries = roster.map((r, index) => {
    if (!r || !r.address) throw new Error(`buildRoster: row ${index} has no address`);
    if (r.address === '0x0000000000000000000000000000000000000000') {
      throw new Error(`buildRoster: row ${index} is the zero address`);
    }
    const amount = typeof r.amount === 'bigint' ? r.amount : toUnits(r.amount);
    if (amount <= 0n) throw new Error(`buildRoster: row ${index} has a non-positive amount`);
    return { index, recipient: r.address, amount, salt: randomSalt() };
  });

  const leaves = entries.map((e) => hashLeaf(runId, e.index, e.recipient, e.amount, e.salt));
  const { root, proofs } = buildTree(leaves);

  entries.forEach((e, i) => {
    e.leaf = leaves[i];
    e.proof = proofs[i];
  });

  const total = entries.reduce((acc, e) => acc + e.amount, 0n);

  return { root, total, totalHuman: fromUnits(total), entries };
}

/** The off-chain package handed to one employee. Contains their salary — deliver privately. */
export function claimPackage({ runId, contract, chainId, entry }) {
  return {
    envelope: 'claim-package.v1',
    chainId: chainId ?? ARBITRUM_SEPOLIA_CHAIN_ID,
    contract,
    runId: String(runId),
    index: entry.index,
    recipient: entry.recipient,
    amount: entry.amount.toString(),
    amountHuman: fromUnits(entry.amount),
    salt: entry.salt,
    proof: entry.proof,
  };
}

/** Validate the shape of a pasted claim package before it is trusted anywhere. */
export function parseClaimPackage(json) {
  const pkg = typeof json === 'string' ? JSON.parse(json) : json;
  if (!pkg || pkg.envelope !== 'claim-package.v1') {
    throw new Error('Not an Envelope claim package');
  }
  if (!pkg.contract || !/^0x[0-9a-fA-F]{40}$/.test(pkg.contract)) {
    throw new Error('Claim package has no valid contract address');
  }
  if (!/^0x[0-9a-fA-F]{64}$/.test(pkg.salt)) {
    throw new Error('Claim package has an invalid salt');
  }
  if (!Array.isArray(pkg.proof) || !pkg.proof.every((p) => /^0x[0-9a-fA-F]{64}$/.test(p))) {
    throw new Error('Claim package has an invalid proof');
  }
  if (!Number.isInteger(Number(pkg.index)) || Number(pkg.index) < 0) {
    throw new Error('Claim package has an invalid index');
  }
  return {
    ...pkg,
    runId: BigInt(pkg.runId),
    index: Number(pkg.index),
    amount: BigInt(pkg.amount),
  };
}
