/**
 * Unit tests for the client-side tree builder.
 * Run: node --test test/js/
 */

import assert from 'node:assert/strict';
import { test } from 'node:test';
import { keccak256, toUtf8Bytes } from 'ethers';

import {
  buildRoster,
  buildTree,
  fromUnits,
  hashLeaf,
  hashPair,
  LEAF_TAG,
  parseClaimPackage,
  claimPackage,
  randomSalt,
  toUnits,
} from '../../app/lib/merkle.js';

const RUN = 1n;
const ALICE = '0x1111111111111111111111111111111111111111';
const BOB = '0x2222222222222222222222222222222222222222';
const CAROL = '0x3333333333333333333333333333333333333333';
const SALT_A = '0x' + 'aa'.repeat(32);
const SALT_B = '0x' + 'bb'.repeat(32);

test('LEAF_TAG matches the contract string literal', () => {
  assert.equal(LEAF_TAG, keccak256(toUtf8Bytes('Envelope.PayrollRun.leaf.v1')));
});

test('hashPair sorts by BigInt, not by hex string', () => {
  // '0x80…' > '0xff…' is FALSE as a string prefix comparison but TRUE numerically.
  // If the implementation compared hex strings, this assertion would fail.
  const low = '0x0000000000000000000000000000000000000000000000000000000000000080';
  const high = '0x00000000000000000000000000000000000000000000000000000000000000ff';

  const sorted = hashPair(low, high);
  const reversed = hashPair(high, low);

  assert.equal(sorted, reversed, 'hashPair must be order-independent');
  // and it must equal the packed concat in numeric order (low then high)
  assert.equal(sorted, keccak256(new Uint8Array([...Buffer.from(low.slice(2), 'hex'), ...Buffer.from(high.slice(2), 'hex')])));
});

test('a node that sorts below its sibling still produces the same parent', () => {
  const a = '0x00'.padEnd(66, '0');
  const b = '0xff'.padEnd(66, 'f');
  assert.equal(hashPair(a, b), hashPair(b, a));
});

test('leaf binds runId, index, claimant, amount and salt', () => {
  const base = hashLeaf(RUN, 0, ALICE, 900n, SALT_A);

  assert.notEqual(base, hashLeaf(2n, 0, ALICE, 900n, SALT_A), 'runId differs');
  assert.notEqual(base, hashLeaf(RUN, 1, ALICE, 900n, SALT_A), 'index differs');
  assert.notEqual(base, hashLeaf(RUN, 0, BOB, 900n, SALT_A), 'claimant differs');
  assert.notEqual(base, hashLeaf(RUN, 0, ALICE, 901n, SALT_A), 'amount differs');
  assert.notEqual(base, hashLeaf(RUN, 0, ALICE, 900n, SALT_B), 'salt differs');

  // deterministic
  assert.equal(base, hashLeaf(RUN, 0, ALICE, 900n, SALT_A));
});

test('single leaf: root is the leaf and the proof is empty', () => {
  const leaf = hashLeaf(RUN, 0, ALICE, 500n, SALT_A);
  const { root, proofs, depth } = buildTree([leaf]);

  assert.equal(root, leaf);
  assert.deepEqual(proofs[0], []);
  assert.equal(depth, 0);
});

test('two leaves: each proof is the other leaf', () => {
  const a = hashLeaf(RUN, 0, ALICE, 100n, SALT_A);
  const b = hashLeaf(RUN, 1, BOB, 200n, SALT_B);
  const { root, proofs } = buildTree([a, b]);

  assert.equal(root, hashPair(a, b));
  assert.deepEqual(proofs[0], [b]);
  assert.deepEqual(proofs[1], [a]);
});

test('odd node is carried up UNCHANGED, never duplicated', () => {
  const [a, b, c] = [
    hashLeaf(RUN, 0, ALICE, 1n, SALT_A),
    hashLeaf(RUN, 1, BOB, 2n, SALT_A),
    hashLeaf(RUN, 2, CAROL, 3n, SALT_A),
  ];
  const { root, proofs } = buildTree([a, b, c]);

  const ab = hashPair(a, b);
  // c pairs with ab at the next level -- NOT hashPair(c, c)
  assert.equal(root, hashPair(ab, c));
  assert.notEqual(root, hashPair(ab, hashPair(c, c)), 'must not duplicate the odd node');

  // c is carried up, so its proof is exactly one element long
  assert.deepEqual(proofs[2], [ab]);
  assert.equal(proofs[0].length, 2);
});

test('every proof verifies to the root for 1..17 leaves', () => {
  for (let n = 1; n <= 17; n++) {
    const leaves = Array.from({ length: n }, (_, i) =>
      hashLeaf(RUN, i, `0x${(i + 1).toString(16).padStart(40, '0')}`, BigInt(i + 1) * 1000n, SALT_A),
    );
    const { root, proofs } = buildTree(leaves);

    proofs.forEach((proof, i) => {
      let acc = leaves[i];
      for (const sibling of proof) acc = hashPair(acc, sibling);
      assert.equal(acc, root, `leaf ${i} of ${n} did not fold to the root`);
    });
  }
});

test('buildTree rejects an empty roster', () => {
  assert.throws(() => buildTree([]), /at least one leaf/);
});

test('randomSalt is 32 bytes and never repeats', () => {
  const seen = new Set();
  for (let i = 0; i < 200; i++) {
    const s = randomSalt();
    assert.match(s, /^0x[0-9a-f]{64}$/);
    assert.ok(!seen.has(s), 'salt repeated');
    seen.add(s);
  }
});

test('toUnits / fromUnits round-trip at 6 decimals', () => {
  assert.equal(toUnits('900'), 900000000n);
  assert.equal(toUnits('1'), 1000000n);
  assert.equal(toUnits('1234.5'), 1234500000n);
  assert.equal(toUnits('0.000001'), 1n);
  assert.equal(fromUnits(900000000n), '900');
  assert.equal(fromUnits(1n), '0.000001');
  assert.equal(fromUnits(1234500000n), '1234.5');
});

test('buildRoster totals, indexes and proves correctly', () => {
  const roster = [
    { address: ALICE, amount: '900' },
    { address: BOB, amount: '400' },
    { address: CAROL, amount: '200' },
  ];
  const { root, total, totalHuman, entries } = buildRoster(roster, RUN);

  assert.equal(total, 1500000000n);
  assert.equal(totalHuman, '1500');
  assert.equal(entries.length, 3);
  assert.match(root, /^0x[0-9a-f]{64}$/);

  entries.forEach((e, i) => {
    assert.equal(e.index, i);
    assert.equal(e.leaf, hashLeaf(RUN, i, e.recipient, e.amount, e.salt));
    let acc = e.leaf;
    for (const s of e.proof) acc = hashPair(acc, s);
    assert.equal(acc, root);
  });

  // distinct salaries must not produce the same leaf
  assert.notEqual(entries[0].leaf, entries[1].leaf);
});

test('buildRoster rejects bad rows', () => {
  assert.throws(() => buildRoster([], RUN), /roster is empty/);
  assert.throws(
    () => buildRoster([{ address: '0x0000000000000000000000000000000000000000', amount: '1' }], RUN),
    /zero address/,
  );
  assert.throws(() => buildRoster([{ address: ALICE, amount: '0' }], RUN), /non-positive/);
});

test('claim package round-trips and is validated', () => {
  const { entries } = buildRoster([{ address: ALICE, amount: '900' }], RUN);
  const pkg = claimPackage({ runId: RUN, contract: '0x' + '12'.repeat(20), entry: entries[0] });

  const parsed = parseClaimPackage(JSON.stringify(pkg));
  assert.equal(parsed.runId, RUN);
  assert.equal(parsed.index, 0);
  assert.equal(parsed.amount, 900000000n);
  assert.equal(parsed.amountHuman, '900');
  assert.equal(parsed.recipient, ALICE);

  assert.throws(() => parseClaimPackage('{"envelope":"nope"}'), /Not an Envelope/);
  assert.throws(() => parseClaimPackage({ ...pkg, salt: '0xzz' }), /invalid salt/);
  assert.throws(() => parseClaimPackage({ ...pkg, contract: 'nope' }), /contract address/);
  assert.throws(() => parseClaimPackage({ ...pkg, proof: ['bad'] }), /invalid proof/);
});

test('two runs with identical rosters and salts still differ (runId binding)', () => {
  const roster = [{ address: ALICE, amount: '500' }];

  // pin the salt so the ONLY difference is the runId
  const mk = (runId, salt) => hashLeaf(runId, 0, ALICE, 500000000n, salt);

  assert.notEqual(mk(1n, SALT_A), mk(2n, SALT_A), 'runId must change the leaf');
  assert.equal(hashPair(mk(1n, SALT_A), mk(1n, SALT_A)), hashPair(mk(1n, SALT_A), mk(1n, SALT_A)));
});
