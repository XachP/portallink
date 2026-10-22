// PortalLink relayer: watches TransferSent on every chain in a profile, gathers threshold
// attestations and submits receiveTransfer on the destination. Stateless-safe: on restart it
// re-scans from its cursor and skips anything the destination already marked processed.
//
//   node relayer.mjs --profile testnet [--once] [--from-latest]
//   env: RELAYER_KEY_FILE (pays destination gas), ATTESTER_KEYS or ATTESTER_URLS
import fs from 'node:fs';
import path from 'node:path';
import { ethers } from 'ethers';
import {
  ROOT, NETWORKS, KIND, GATEWAY_ABI, loadDeployment, provider, readKeyFile, networksForProfile,
  argv, log, anvilKey, fmt, sendAndWait,
} from './lib.mjs';
import { loadAttesters } from './attester.mjs';

const profile = argv('profile', 'local');
const once = !!argv('once');
const POLL_MS = Number(process.env.POLL_MS || 6000);
const statePath = path.join(ROOT, 'relayer', `state-${profile}.json`);
const feedPath = path.join(ROOT, 'docs', 'data', `${profile}-feed.json`);

const nets = networksForProfile(profile).filter((n) => loadDeployment(n));
if (nets.length < 2) { console.error(`need deployments for at least two ${profile} networks in deploy/`); process.exit(1); }

// One gas-paying key per chain: RELAYER_KEY_FILE_<NETWORK> (e.g. RELAYER_KEY_FILE_MEZO_TESTNET)
// falls back to RELAYER_KEY_FILE. Relaying is permissionless; this key holds no bridge power.
const relayerKey = (n) => {
  if (profile === 'local') return anvilKey(1);
  const f = process.env[`RELAYER_KEY_FILE_${n.toUpperCase().replace(/-/g, '_')}`] || process.env.RELAYER_KEY_FILE;
  if (!f) throw new Error(`set RELAYER_KEY_FILE or RELAYER_KEY_FILE_${n.toUpperCase().replace(/-/g, '_')}`);
  return readKeyFile(f);
};
const chains = Object.fromEntries(nets.map((n) => {
  const prov = provider(n);
  const dep = loadDeployment(n);
  const signer = new ethers.Wallet(relayerKey(n), prov);
  return [n, { name: n, net: NETWORKS[n], dep, prov, signer, gw: new ethers.Contract(dep.gateway, GATEWAY_ABI(), signer) }];
}));
const byChainId = (id) => Object.values(chains).find((c) => BigInt(c.net.chainId) === BigInt(id));
const attesters = loadAttesters(profile);

const state = fs.existsSync(statePath) ? JSON.parse(fs.readFileSync(statePath, 'utf8')) : { cursor: {} };
const feed = fs.existsSync(feedPath) ? JSON.parse(fs.readFileSync(feedPath, 'utf8')) : { transfers: [] };
const saveState = () => fs.writeFileSync(statePath, JSON.stringify(state, null, 2));
const saveFeed = () => {
  fs.mkdirSync(path.dirname(feedPath), { recursive: true });
  feed.updated = new Date().toISOString();
  feed.transfers.sort((a, b) => (b.srcTime || 0) - (a.srcTime || 0));
  fs.writeFileSync(feedPath, JSON.stringify(feed, null, 2) + '\n');
};
const upsert = (row) => {
  const i = feed.transfers.findIndex((r) => r.id === row.id);
  if (i === -1) feed.transfers.push(row); else feed.transfers[i] = { ...feed.transfers[i], ...row };
};

async function collectSignatures(ptr, threshold) {
  const results = await Promise.allSettled(attesters.map((a) => a.attest(ptr)));
  const ok = results.filter((r) => r.status === 'fulfilled').map((r) => r.value);
  for (const r of results) if (r.status === 'rejected') log(`  attester refused: ${r.reason.message}`);
  // all honest attesters rebuild the same struct; drop any that disagree with the majority
  const id = ok[0]?.id;
  const agree = ok.filter((r) => r.id === id);
  if (agree.length < threshold) return null;
  agree.sort((a, b) => (BigInt(a.signer) < BigInt(b.signer) ? -1 : 1));
  return { transfer: agree[0].transfer, sigs: agree.slice(0, threshold).map((r) => r.signature), signers: agree.map((r) => r.signer) };
}

async function scan(src) {
  const head = await src.prov.getBlockNumber();
  const safe = head - src.net.confirmations;
  let from = state.cursor[src.name] ?? (argv('from-latest') ? safe : src.dep.block);
  if (from > safe) return;
  while (from <= safe) {
    const to = Math.min(from + src.net.logChunk - 1, safe);
    const logs = await src.gw.queryFilter(src.gw.filters.TransferSent(), from, to);
    for (const ev of logs) await handle(src, ev);
    state.cursor[src.name] = to + 1;
    saveState();
    from = to + 1;
  }
}

async function handle(src, ev) {
  const { id, dstChainId, nonce, kind, sender, recipient, amount } = ev.args;
  const dst = byChainId(dstChainId);
  const srcBlock = await src.prov.getBlock(ev.blockNumber);
  const asset = Number(kind) === 0 ? src.net.native : (dst?.net.native ?? '?');
  const row = {
    id, kind: KIND[Number(kind)], src: src.name, dst: dst?.name ?? String(dstChainId), nonce: Number(nonce),
    sender, recipient, amount: amount.toString(), asset, srcTx: ev.transactionHash, srcBlock: ev.blockNumber,
    srcTime: srcBlock?.timestamp ?? null,
  };
  if (!dst) { upsert({ ...row, status: 'unroutable' }); saveFeed(); return; }
  if (await dst.gw.processed(id)) { upsert({ ...row, status: 'delivered' }); saveFeed(); return; }

  log(`${src.name} #${nonce} ${row.kind} ${fmt(amount, asset)} -> ${dst.name} ${recipient}`);
  const threshold = Number(await dst.gw.threshold());
  const got = await collectSignatures({ src: src.name, blockNumber: ev.blockNumber, txHash: ev.transactionHash, logIndex: ev.index }, threshold);
  if (!got) { upsert({ ...row, status: 'awaiting-attestations' }); saveFeed(); log('  not enough attestations yet'); return; }
  try {
    const rc = await sendAndWait(dst.signer, await dst.gw.receiveTransfer.populateTransaction(got.transfer, got.sigs), 'receiveTransfer');
    log(`  delivered in ${rc.hash} (block ${rc.blockNumber}) signed by ${got.signers.length}/${attesters.length}`);
    upsert({ ...row, status: 'delivered', dstTx: rc.hash, dstBlock: rc.blockNumber, attestedBy: got.signers });
  } catch (e) {
    const reason = e.shortMessage || e.message;
    if (await dst.gw.processed(id).catch(() => false)) upsert({ ...row, status: 'delivered' });
    else { upsert({ ...row, status: 'failed', error: reason.slice(0, 200) }); log(`  delivery failed: ${reason}`); }
  }
  saveFeed();
}

async function tick() {
  for (const c of Object.values(chains)) {
    try { await scan(c); } catch (e) { log(`scan ${c.name} error: ${e.shortMessage || e.message}`); }
  }
}

log(`relayer ${Object.values(chains).map((c) => c.signer.address).join('/')} profile=${profile} chains=${nets.join(',')} attesters=${attesters.length}`);
await tick();
if (!once) setInterval(tick, POLL_MS);
