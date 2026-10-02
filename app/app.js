/**
 * Envelope — frontend.
 *
 * No backend. Salts, leaves and the Merkle root are built in the browser by app/lib/merkle.js,
 * the same module the Solidity parity tests exercise.
 *
 * Wallet model: this app only ever asks the user's own wallet to sign. It never sees, stores or
 * transmits a private key, and it never sends anything to a server.
 */

import {
  BrowserProvider,
  Contract,
  JsonRpcProvider,
  formatUnits,
  isAddress,
  parseUnits,
} from 'ethers';
import {
  ARBITRUM_SEPOLIA_CHAIN_ID,
  buildRoster,
  fromUnits,
  hashLeaf,
  parseClaimPackage,
  claimPackage as makePackage,
  USDG_ARBITRUM_SEPOLIA,
  USDG_DECIMALS,
} from './lib/merkle.js';

const CHAIN_ID = ARBITRUM_SEPOLIA_CHAIN_ID;

const CHAIN_PARAMS = {
  chainId: '0x' + CHAIN_ID.toString(16), // 0x66eea
  chainName: 'Arbitrum Sepolia',
  nativeCurrency: { name: 'Ethereum', symbol: 'ETH', decimals: 18 },
  rpcUrls: ['https://sepolia-rollup.arbitrum.io/rpc'],
  blockExplorerUrls: ['https://sepolia.arbiscan.io'],
};

const PAYROLL_ABI = [
  'function createRun(bytes32 root, uint64 deadline, uint256 amount) returns (uint256)',
  'function claim(uint256 runId, uint256 index, uint256 amount, bytes32 salt, bytes32[] proof)',
  'function reclaim(uint256 runId)',
  'function runs(uint256) view returns (address employer, bytes32 root, uint64 deadline, uint256 totalDeposited, uint256 totalClaimed, bool reclaimed)',
  'function leafClaimed(uint256, uint256) view returns (bool)',
  'function verifyClaim(uint256 runId, uint256 index, address claimant, uint256 amount, bytes32 salt, bytes32[] proof) view returns (bool)',
  'function remaining(uint256) view returns (uint256)',
  'function runCount() view returns (uint256)',
  'function nextRunId() view returns (uint256)',
  'function leafFor(uint256 runId, uint256 index, address claimant, uint256 amount, bytes32 salt) pure returns (bytes32)',
  'event RunCreated(uint256 indexed runId, address indexed employer, bytes32 root, uint64 deadline, uint256 totalDeposited)',
];

const ERC20_ABI = [
  'function approve(address spender, uint256 amount) returns (bool)',
  'function allowance(address owner, address spender) view returns (uint256)',
  'function balanceOf(address) view returns (uint256)',
  'function decimals() view returns (uint8)',
];

// ─────────────────────────────────────────────────────────────── state

const S = {
  provider: null,
  signer: null,
  account: null,
  payroll: null,     // read-only or signer-bound contract
  readPayroll: null, // always read-only, works without a wallet
  built: null,       // { root, total, entries, runId, deadline }
};

// ─────────────────────────────────────────────────────────────── helpers

const $ = (id) => document.getElementById(id);

function toast(msg, bad = false) {
  const el = $('toast');
  el.textContent = msg;
  el.classList.toggle('bad', bad);
  el.classList.add('show');
  clearTimeout(toast._t);
  toast._t = setTimeout(() => el.classList.remove('show'), bad ? 6500 : 4200);
}

const short = (a) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : '—');
const usdg = (units) => Number(formatUnits(units, USDG_DECIMALS)).toLocaleString(undefined, {
  minimumFractionDigits: 0,
  maximumFractionDigits: USDG_DECIMALS,
});
const dateStr = (ts) => new Date(Number(ts) * 1000).toLocaleString(undefined, {
  dateStyle: 'medium', timeStyle: 'short',
});

function setView(name) {
  document.querySelectorAll('.view').forEach((v) => v.classList.remove('is-active'));
  $('view-' + name).classList.add('is-active');
  document.querySelectorAll('.tab').forEach((t) => {
    const on = t.dataset.view === name;
    t.classList.toggle('is-active', on);
    t.setAttribute('aria-selected', String(on));
  });
  location.hash = name === 'public' ? '' : name;
}

/** Read-only contract — the public view must work with no wallet at all. */
let readProvider = null;

/** Allow ?rpc=… to point reads at another node (local dev, or a judge's own endpoint). */
function rpcUrl() {
  const override = new URLSearchParams(location.search).get('rpc');
  return override || CHAIN_PARAMS.rpcUrls[0];
}

function getReadProvider() {
  if (!readProvider) {
    readProvider = new JsonRpcProvider(rpcUrl(), undefined, { staticNetwork: true });
  }
  return readProvider;
}

function readContract(address) {
  if (!address) return null;
  return new Contract(address, PAYROLL_ABI, getReadProvider());
}

// ─────────────────────────────────────────────────────────────── wallet

async function connect() {
  if (!window.ethereum) {
    toast('No wallet found. Open this page inside your wallet browser (e.g. MetaMask).', true);
    return;
  }

  try {
    const provider = new BrowserProvider(window.ethereum);
    const accounts = await provider.send('eth_requestAccounts', []);
    const network = await provider.getNetwork();

    if (Number(network.chainId) !== CHAIN_ID) {
      try {
        await window.ethereum.request({
          method: 'wallet_switchEthereumChain',
          params: [{ chainId: CHAIN_PARAMS.chainId }],
        });
      } catch (err) {
        if (err.code === 4902) {
          await window.ethereum.request({
            method: 'wallet_addEthereumChain',
            params: [CHAIN_PARAMS],
          });
        } else {
          throw err;
        }
      }
    }

    const fresh = new BrowserProvider(window.ethereum);
    S.provider = fresh;
    S.signer = await fresh.getSigner();
    S.account = accounts[0];

    $('netBadge').textContent = `Arbitrum Sepolia (${short(S.account)})`;
    $('netBadge').className = 'badge badge-ok';
    $('connectBtn').textContent = 'Connected';
    $('connectBtn').disabled = true;
    $('employerConnect').classList.add('hidden');
    $('employerBody').classList.remove('hidden');
    $('myRuns').classList.remove('hidden');

    await refreshRuns();
    toast('Connected on Arbitrum Sepolia');
  } catch (err) {
    toast(err.shortMessage || err.message || 'Could not connect', true);
  }
}

/** Resolve the deployed contract address: from the URL hash, then localStorage, then ask. */
function contractAddress() {
  const fromHash = new URLSearchParams(location.search).get('c');
  if (fromHash && isAddress(fromHash)) return fromHash;
  const stored = localStorage.getItem('envelope.contract');
  return stored && isAddress(stored) ? stored : null;
}

function payrollWithSigner() {
  const addr = contractAddress();
  if (!addr) throw new Error('No contract address set. Add ?c=0x… to the URL.');
  return new Contract(addr, PAYROLL_ABI, S.signer);
}

function readPayrollContract() {
  return readContract(contractAddress());
}

// ─────────────────────────────────────────────────────────────── public view

async function loadRun(runId) {
  const c = readPayrollContract();
  if (!c) {
    $('publicEmpty').classList.remove('hidden');
    $('publicEmpty').textContent =
      'No contract address set. Open this page with ?c=0xYourPayrollRun to read a run.';
    return;
  }

  try {
    const r = await c.runs(runId);
    if (r.employer === '0x0000000000000000000000000000000000000000') {
      $('publicCard').classList.add('hidden');
      $('publicEmpty').classList.remove('hidden');
      $('publicEmpty').textContent = `Run #${runId} does not exist.`;
      return;
    }

    const deposited = r.totalDeposited;
    const claimed = r.totalClaimed;
    const remaining = deposited - claimed;
    const pct = deposited > 0n ? Number((claimed * 10000n) / deposited) / 100 : 0;
    const pctLabel = `${pct.toFixed(pct === 0 || pct === 100 ? 0 : 1)}%`;

    $('pRunId').textContent = runId;
    $('pClaimed').textContent = usdg(claimed);
    $('pDeposited').textContent = `${usdg(deposited)} USDG`;
    $('pBar').style.width = `${Math.min(100, pct)}%`;

    // State the remainder and the share outright — the reader should not do the subtraction.
    $('pProgressNote').textContent =
      remaining > 0n
        ? `${usdg(remaining)} USDG still held. ${pctLabel} of this run has been claimed.`
        : `Fully claimed. Nothing is still held.`;
    $('pEmployer').textContent = r.employer;
    $('pRoot').textContent = r.root;
    $('pDeadline').textContent = dateStr(r.deadline);
    $('pReclaimed').classList.toggle('hidden', !r.reclaimed);

    $('publicEmpty').classList.add('hidden');
    $('publicCard').classList.remove('hidden');
  } catch (err) {
    toast(err.shortMessage || err.message || 'Could not read that run', true);
  }
}

async function refreshRuns() {
  const c = readPayrollContract();
  if (!c) return;

  try {
    const count = Number(await c.runCount());
    if (count === 0) return;

    const items = [];
    for (let i = count; i >= 1 && items.length < 12; i--) {
      const r = await c.runs(i);
      items.push(`
        <div class="run-item">
          <div>
            <div class="id">Run #${i}</div>
            <div class="nums">${usdg(r.totalClaimed)} paid out of ${usdg(r.totalDeposited)} set aside</div>
          </div>
          <button class="btn btn-sm" data-run="${i}">View</button>
        </div>`);
    }

    $('myRunsList').innerHTML = items.join('');
    $('myRunsList').querySelectorAll('button[data-run]').forEach((b) => {
      b.addEventListener('click', async () => {
        setView('public');
        $('runInput').value = b.dataset.run;
        await loadRun(b.dataset.run);
      });
    });
  } catch {
    /* the runs list is a convenience; failing quietly is fine */
  }
}

// ─────────────────────────────────────────────────────────────── employer

function addRow(address = '', amount = '') {
  const row = document.createElement('div');
  row.className = 'row';
  row.innerHTML = `
    <input class="input addr" placeholder="0x recipient address" value="${address}" spellcheck="false" />
    <input class="input amt" type="number" min="0" step="0.000001" placeholder="Amount" value="${amount}" />
    <button class="del" title="Remove" aria-label="Remove row">×</button>`;
  row.querySelector('.del').addEventListener('click', () => {
    row.remove();
    updateTotal();
  });
  row.querySelectorAll('input').forEach((i) => i.addEventListener('input', updateTotal));
  $('rows').appendChild(row);
  updateTotal();
}

function readRows() {
  const rows = [...$('rows').querySelectorAll('.row')];
  return rows.map((r) => ({
    address: r.querySelector('.addr').value.trim(),
    amount: r.querySelector('.amt').value.trim(),
  }));
}

function updateTotal() {
  let total = 0n;
  for (const r of readRows()) {
    if (!r.amount) continue;
    try { total += parseUnits(r.amount, USDG_DECIMALS); } catch { /* ignore partial input */ }
  }
  $('empTotal').textContent = usdg(total);
}

function validateRows() {
  const rows = readRows();
  if (rows.length === 0) throw new Error('Add at least one recipient.');
  for (const [i, r] of rows.entries()) {
    if (!isAddress(r.address)) throw new Error(`Row ${i + 1}: "${r.address || '(empty)'}" is not a valid address.`);
    if (r.address === '0x0000000000000000000000000000000000000000') {
      throw new Error(`Row ${i + 1}: the zero address can never claim.`);
    }
  }
  const seen = new Set();
  for (const r of rows) {
    if (seen.has(r.address.toLowerCase())) throw new Error(`Duplicate recipient ${short(r.address)} — each is one commitment.`);
    seen.add(r.address.toLowerCase());
  }
  return rows;
}

async function buildCommitments() {
  try {
    const roster = validateRows();

    const deadlineValue = $('deadlineInput').value;
    if (!deadlineValue) throw new Error('Pick a claim deadline before building.');

    const c = payrollWithSigner();
    const runId = await c.nextRunId();          // the run this payroll will become

    const built = buildRoster(roster, runId);
    const deadline = BigInt(Math.floor(new Date(deadlineValue + 'T00:00:00').getTime() / 1000));

    S.built = { ...built, runId, deadline };

    $('empRoot').textContent = built.root;
    $('empCount').textContent = String(built.entries.length);
    $('empDeposit').textContent = built.totalHuman;

    $('commitBox').innerHTML = `<div class="commit-list">${
      built.entries.map((e) => `
        <div class="commit-line">
          <span class="who">${short(e.recipient)}</span>
          <span class="amt">${usdg(e.amount)} USDG</span>
        </div>`).join('')
    }</div>`;

    $('fundBox').classList.remove('hidden');
    $('buildBtn').textContent = 'Rebuild commitments';
    toast(`Built ${built.entries.length} commitments · root ${built.root.slice(0, 12)}…`);
  } catch (err) {
    toast(err.shortMessage || err.message || 'Could not build the commitments', true);
  }
}

function downloadPackages() {
  if (!S.built) return;
  const addr = contractAddress() || '0x0000000000000000000000000000000000000000';

  S.built.entries.forEach((e) => {
    const pkg = makePackage({ runId: S.built.runId, contract: addr, chainId: CHAIN_ID, entry: e });
    const blob = new Blob([JSON.stringify(pkg, null, 2)], { type: 'application/json' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = `envelope-run${S.built.runId}-${e.index}-${e.recipient.slice(2, 8)}.json`;
    a.click();
    URL.revokeObjectURL(a.href);
  });

  const master = {
    note: 'MASTER FILE — keep this. Without the salts nobody can build a claim proof.',
    chainId: CHAIN_ID,
    contract: addr,
    runId: String(S.built.runId),
    root: S.built.root,
    total: S.built.total.toString(),
    totalHuman: S.built.totalHuman,
    entries: S.built.entries.map((e) => ({
      index: e.index, recipient: e.recipient, amount: e.amount.toString(),
      amountHuman: fromUnits(e.amount), salt: e.salt, proof: e.proof,
    })),
  };
  const blob = new Blob([JSON.stringify(master, null, 2)], { type: 'application/json' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = `envelope-run${S.built.runId}-MASTER-do-not-lose.json`;
  a.click();
  URL.revokeObjectURL(a.href);

  toast(`Downloaded ${S.built.entries.length} claim packages + master file`);
}

async function approve() {
  if (!S.built) return;
  const addr = contractAddress();
  const token = new Contract(USDG_ARBITRUM_SEPOLIA, ERC20_ABI, S.signer);

  try {
    $('approveBtn').disabled = true;
    $('fundStatus').textContent = 'Confirm the approval in your wallet…';
    const tx = await token.approve(addr, S.built.total);
    $('fundStatus').textContent = `Approval sent: ${tx.hash}`;
    await tx.wait();
    // Exactly one dominant action at a time: approving hands the weight to the next step.
    $('createBtn').disabled = false;
    $('createBtn').classList.add('btn-primary');
    $('approveBtn').classList.remove('btn-primary');
    $('approveBtn').disabled = true;
    $('approveBtn').textContent = '1. Approved';
    $('fundStatus').textContent = 'Approved. Now create the run to lock the funds.';
    toast('USDG approved');
  } catch (err) {
    $('approveBtn').disabled = false;
    $('fundStatus').textContent = '';
    toast(err.shortMessage || err.message || 'Approval failed', true);
  }
}

async function createRun() {
  if (!S.built) return;
  const c = payrollWithSigner();

  try {
    $('createBtn').disabled = true;
    $('fundStatus').textContent = 'Confirm in your wallet…';
    const tx = await c.createRun(S.built.root, S.built.deadline, S.built.total);
    $('fundStatus').textContent = `Sent: ${tx.hash}`;
    await tx.wait();

    $('fundStatus').innerHTML =
      `Run created. <strong>Send the matching claim package to each recipient — the salts are the only way they can claim.</strong>`;
    toast('Payroll run created and funded');
    await refreshRuns();
  } catch (err) {
    $('createBtn').disabled = false;
    $('fundStatus').textContent = '';
    toast(err.shortMessage || err.message || 'Could not create the run', true);
  }
}

// ─────────────────────────────────────────────────────────────── employee

let pendingPackage = null;

async function checkPackage() {
  try {
    pendingPackage = parseClaimPackage($('pkgInput').value.trim());
  } catch (err) {
    $('claimResult').classList.add('hidden');
    toast(err.message, true);
    return;
  }

  const p = pendingPackage;
  $('cAmount').textContent = p.amountHuman;
  $('cMeta').textContent =
    `Commitment ${p.index} in run #${p.runId}, made out to ${short(p.recipient)}. Contract ${short(p.contract)}.`;

  // Local check first: does this proof actually fold to the on-chain root?
  let okLocal = false;
  let rootOnChain = null;
  const c = readContract(p.contract);
  if (c) {
    try {
      const r = await c.runs(p.runId);
      rootOnChain = r.root;
      const leaf = hashLeaf(p.runId, p.index, p.recipient, p.amount, p.salt);
      okLocal = await c.verifyClaim(p.runId, p.index, p.recipient, p.amount, p.salt, p.proof);
    } catch (err) {
      toast(err.shortMessage || err.message || 'Could not reach the contract', true);
    }
  }

  const badge = $('cBadge');
  const canClaim = S.account && S.account.toLowerCase() === p.recipient.toLowerCase();
  const btn = $('claimBtn');

  if (!S.account) {
    badge.className = 'notice notice-warn';
    badge.textContent = `Connect the wallet for ${short(p.recipient)} to claim. The commitment is bound to that address, so no other wallet can.`;
    btn.disabled = true;
  } else if (!canClaim) {
    badge.className = 'notice notice-warn';
    badge.textContent = `This commitment is bound to ${short(p.recipient)}. You are connected as ${short(S.account)} — that wallet cannot claim it.`;
    btn.disabled = true;
  } else if (!okLocal) {
    badge.className = 'notice notice-warn';
    badge.textContent = 'This package does not verify against the on-chain root. It may have been altered, or it belongs to another run.';
    btn.disabled = true;
  } else {
    badge.className = 'notice notice-good';
    badge.textContent = 'Verified against the on-chain Merkle root. This package is genuine and yours to claim.';
    btn.disabled = false;
    btn.textContent = `Claim ${p.amountHuman} USDG`;
  }

  $('claimStatus').textContent = rootOnChain ? `On-chain root: ${rootOnChain}` : '';
  $('claimResult').classList.remove('hidden');
}

async function doClaim() {
  if (!pendingPackage) return;
  const p = pendingPackage;
  const c = payrollWithSigner();

  try {
    $('claimBtn').disabled = true;
    $('claimStatus').textContent = 'Confirm in your wallet…';
    const tx = await c.claim(p.runId, p.index, p.amount, p.salt, p.proof);
    $('claimStatus').textContent = `Sent: ${tx.hash}`;
    await tx.wait();

    $('cBadge').className = 'notice notice-good';
    $('cBadge').textContent = `Paid. ${p.amountHuman} USDG sent to ${short(p.recipient)}. The public total has been updated — and only your amount became visible.`;
    $('claimBtn').textContent = 'Claimed';
    toast(`Claimed ${p.amountHuman} USDG`);

    const runId = $('runInput').value || p.runId;
    if (runId) loadRun(runId);
  } catch (err) {
    $('claimBtn').disabled = false;
    $('claimStatus').textContent = '';
    toast(err.shortMessage || err.message || 'Claim failed', true);
  }
}

// ─────────────────────────────────────────────────────────────── wiring

function init() {
  document.querySelectorAll('.tab').forEach((t) =>
    t.addEventListener('click', () => setView(t.dataset.view)));

  $('connectBtn').addEventListener('click', connect);

  $('loadRunBtn').addEventListener('click', () => {
    const v = $('runInput').value;
    if (v) loadRun(v);
  });
  $('refreshRunsBtn').addEventListener('click', refreshRuns);
  $('runInput').addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && $('runInput').value) loadRun($('runInput').value);
  });

  $('addRowBtn').addEventListener('click', () => addRow());
  $('buildBtn').addEventListener('click', buildCommitments);
  $('downloadBtn').addEventListener('click', downloadPackages);
  $('approveBtn').addEventListener('click', approve);
  $('createBtn').addEventListener('click', createRun);

  $('verifyPkgBtn').addEventListener('click', checkPackage);
  $('clearPkgBtn').addEventListener('click', () => {
    $('pkgInput').value = '';
    $('claimResult').classList.add('hidden');
    pendingPackage = null;
  });
  $('claimBtn').addEventListener('click', doClaim);

  // default claim deadline: 30 days out
  const d = new Date(Date.now() + 30 * 864e5);
  $('deadlineInput').value = d.toISOString().slice(0, 10);

  addRow();
  addRow();

  // a contract address in the URL lets a judge open the public view with no setup
  const c = contractAddress();
  if (c) {
    $('runInput').value = $('runInput').value || '1';
    loadRun($('runInput').value);
    refreshRuns();
  }

  const hash = location.hash.replace('#', '');
  if (['public', 'employer', 'claim'].includes(hash)) setView(hash);

  if (window.ethereum) {
    window.ethereum.on?.('accountsChanged', () => location.reload());
    window.ethereum.on?.('chainChanged', () => location.reload());
  }
}

init();
