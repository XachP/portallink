/* PortalLink dashboard: reads both chains directly from public RPCs. No backend. */
const CFG = window.PORTALLINK;
const NETS = CFG.networks;
const GW_ABI = [
  'event TransferSent(bytes32 indexed id,uint64 indexed dstChainId,uint64 nonce,uint8 kind,address indexed sender,address recipient,uint256 amount)',
  'event TransferReceived(bytes32 indexed id,uint64 indexed srcChainId,uint64 nonce,uint8 kind,address indexed recipient,uint256 amount)',
  'function route(uint64) view returns (address peer,address wrapped,uint256 lockedOut)',
  'function processed(bytes32) view returns (bool)',
  'function paused() view returns (bool)',
  'function threshold() view returns (uint8)',
  'function totalOwed() view returns (uint256)',
  'function lockNative(uint64 dstChainId,address recipient) payable returns (bytes32)',
  'function burnWrapped(uint64 dstChainId,address recipient,uint256 amount) returns (bytes32)',
];
const ERC20 = ['function totalSupply() view returns (uint256)', 'function balanceOf(address) view returns (uint256)'];
const $ = (id) => document.getElementById(id);
const short = (a) => (a ? `${a.slice(0, 8)}…${a.slice(-6)}` : '—');
const amt = (v, sym) => `${Number(ethers.formatEther(v)).toLocaleString('en-US', { maximumFractionDigits: 6 })} ${sym}`;
const color = (n) => (NETS[n].native === 'BTC' ? 'var(--btc)' : 'var(--pot)');
const label = (n) => (n.startsWith('portaldot') ? 'Portaldot V3' : 'Mezo');
const txLink = (n, h) => (h ? (NETS[n].explorer.includes('mezo') ? `<a class="mono" target="_blank" href="${NETS[n].explorer}/tx/${h}">${short(h)}</a>` : `<span class="mono" title="${h}">${short(h)}</span>`) : '—');
const addrLink = (n, a) => (a ? (NETS[n].explorer.includes('mezo') ? `<a class="mono" target="_blank" href="${NETS[n].explorer}/address/${a}">${short(a)}</a>` : `<span class="mono" title="${a}">${short(a)}</span>`) : '—');

const P = {}; const G = {};
for (const [n, c] of Object.entries(NETS)) {
  P[n] = new ethers.JsonRpcProvider(c.rpc, c.chainId, { staticNetwork: true, batchMaxCount: 1 });
  if (c.gateway) G[n] = new ethers.Contract(c.gateway, GW_ABI, P[n]);
}
const live = Object.keys(G);
const byChainId = (id) => Object.keys(NETS).find((n) => BigInt(NETS[n].chainId) === BigInt(id));

async function chainState(n) {
  const c = NETS[n];
  const head = await P[n].getBlockNumber().catch(() => null);
  if (!c.gateway) return { n, head };
  const r = NETS[c.remote];
  const [escrow, rt, paused, th, supply] = await Promise.all([
    P[n].getBalance(c.gateway), G[n].route(r.chainId), G[n].paused(), G[n].threshold(),
    new ethers.Contract(c.wrapped, ERC20, P[n]).totalSupply(),
  ]);
  return { n, head, escrow, lockedOut: rt.lockedOut, linked: rt.peer !== ethers.ZeroAddress, paused, th: Number(th), supply };
}

function chainCard(s) {
  const c = NETS[s.n];
  const body = c.gateway ? `
    <div class="kv">
      <div>Gateway</div><div>${addrLink(s.n, c.gateway)}</div>
      <div>${c.wrappedSymbol}</div><div>${addrLink(s.n, c.wrapped)} · supply ${amt(s.supply, c.wrappedSymbol)}</div>
      <div>Escrowed ${c.native}</div><div class="big">${amt(s.lockedOut, c.native)}</div>
      <div>Committee</div><div>${s.th}-of-${c.attesters.length} · ${c.attesters.map(short).join(', ')}</div>
      <div>Route</div><div>${s.linked ? `<span class="ok">linked → ${label(c.remote)}</span>` : '<span class="warn">waiting for peer deployment</span>'}</div>
      <div>State</div><div>${s.paused ? '<span class="bad">PAUSED by guardian</span>' : '<span class="ok">live</span>'} · block ${s.head ?? '?'}</div>
    </div>` : `
    <div class="kv"><div>Status</div><div class="warn">Contracts built &amp; tested; deploy runs automatically once the hackathon tPOT faucet pays out.</div>
    <div>RPC</div><div class="mono">${c.rpc}</div><div>Head</div><div>${s.head ?? 'unreachable'}</div></div>`;
  return `<div class="card chain"><h3><span class="dot" style="background:${color(s.n)}"></span>${label(s.n)} <span class="pill">chain ${c.chainId}</span></h3>${body}</div>`;
}

function solvency(states) {
  const S = Object.fromEntries(states.map((s) => [s.n, s]));
  const rows = [];
  for (const n of live) {
    const c = NETS[n]; const rem = S[c.remote];
    if (!rem || rem.supply === undefined) { rows.push(`<div class="route"><div>${c.native} escrow on ${label(n)}: <b>${amt(S[n].lockedOut, c.native)}</b></div><div class="warn">peer not deployed</div></div>`); continue; }
    const wrapped = rem.supply; const ok = S[n].lockedOut >= wrapped && S[n].escrow >= S[n].lockedOut;
    const pct = S[n].lockedOut === 0n ? 100 : Number((wrapped * 10000n) / S[n].lockedOut) / 100;
    rows.push(`<div class="route"><div>${c.native} escrowed on ${label(n)} <b>${amt(S[n].lockedOut, c.native)}</b> backs ${NETS[c.remote].wrappedSymbol} on ${label(c.remote)} <b>${amt(wrapped, NETS[c.remote].wrappedSymbol)}</b><div class="bar"><i style="width:${Math.min(pct, 100)}%"></i></div></div><div class="${ok ? 'ok' : 'bad'}">${ok ? '✔ fully backed' : '✖ under-collateralised'}</div></div>`);
  }
  return rows.join('') || '<span class="mut">no live gateways yet</span>';
}

async function logsSince(n, fromBlock, head) {
  const out = []; const step = 5000; const start = Math.max(fromBlock, head - step * 20);
  for (let b = start; b <= head; b += step) {
    const l = await G[n].queryFilter(G[n].filters.TransferSent(), b, Math.min(b + step - 1, head)).catch(() => []);
    out.push(...l);
  }
  return out;
}

async function transfers(states) {
  const feed = await fetch('data/testnet-feed.json', { cache: 'no-store' }).then((r) => r.json()).catch(() => ({ transfers: [] }));
  const rows = new Map(feed.transfers.map((t) => [t.id, t]));
  for (const s of states.filter((x) => G[x.n] && x.head)) {
    for (const ev of await logsSince(s.n, NETS[s.n].block, s.head)) {
      const { id, dstChainId, nonce, kind, recipient, amount } = ev.args;
      const dst = byChainId(dstChainId);
      const prev = rows.get(id) || {};
      rows.set(id, { ...prev, id, src: s.n, dst, nonce: Number(nonce), kind: Number(kind) === 0 ? 'NativeLocked' : 'WrappedBurned', recipient, amount: amount.toString(), srcTx: ev.transactionHash, srcBlock: ev.blockNumber, asset: Number(kind) === 0 ? NETS[s.n].native : NETS[dst]?.native });
    }
  }
  const list = [...rows.values()].sort((a, b) => (b.srcTime || b.srcBlock || 0) - (a.srcTime || a.srcBlock || 0)).slice(0, 50);
  await Promise.all(list.map(async (t) => { if (t.status !== 'delivered' && G[t.dst]) t.status = (await G[t.dst].processed(t.id).catch(() => false)) ? 'delivered' : 'pending'; }));
  if (!list.length) return '<tr><td colspan="6" class="mut">No transfers yet. The live round trip runs as soon as the Portaldot side is deployed.</td></tr>';
  return list.map((t) => `<tr><td>${t.srcTime ? new Date(t.srcTime * 1000).toLocaleString() : `block ${t.srcBlock}`}</td>
    <td>${label(t.src)} → ${label(t.dst)}<br><span class="pill">${t.kind === 'NativeLocked' ? 'lock → mint' : 'burn → release'}</span></td>
    <td>${amt(BigInt(t.amount), t.kind === 'NativeLocked' ? NETS[t.src].native : NETS[t.dst].native)}</td>
    <td>${addrLink(t.dst, t.recipient)}</td><td>${txLink(t.src, t.srcTx)}</td>
    <td><span class="st ${t.status === 'delivered' ? 'delivered' : t.status === 'failed' ? 'failed' : 'pending'}">${t.status || 'pending'}</span><br>${txLink(t.dst, t.dstTx)}</td></tr>`).join('');
}

async function refresh() {
  const states = await Promise.all(Object.keys(NETS).map((n) => chainState(n).catch(() => ({ n }))));
  $('chains').innerHTML = states.map(chainCard).join('');
  $('solvency').innerHTML = solvency(states);
  $('rows').innerHTML = await transfers(states);
  $('updated').textContent = `live · ${new Date().toLocaleTimeString()}`;
}

// ------------------------------------------------------------------ wallet
let signer = null;
function directions() {
  const d = [];
  for (const n of live) {
    const c = NETS[n];
    if (!NETS[c.remote]?.gateway) continue;
    d.push({ key: `lock:${n}`, text: `Lock ${c.native} on ${label(n)} → ${NETS[c.remote].wrappedSymbol} on ${label(c.remote)}`, n, op: 'lock' });
    d.push({ key: `burn:${n}`, text: `Burn ${c.wrappedSymbol} on ${label(n)} → ${NETS[c.remote].native} on ${label(c.remote)}`, n, op: 'burn' });
  }
  return d;
}
function fillDirections() {
  const d = directions();
  $('dir').innerHTML = d.length ? d.map((x) => `<option value="${x.key}">${x.text}</option>`).join('') : '<option>Routes open once both gateways are deployed</option>';
  $('go').disabled = !signer || !d.length;
}
$('connect').onclick = async () => {
  if (!window.ethereum) { $('msg').textContent = 'No injected wallet found (MetaMask etc).'; return; }
  const bp = new ethers.BrowserProvider(window.ethereum);
  await bp.send('eth_requestAccounts', []);
  signer = await bp.getSigner();
  $('connect').textContent = short(await signer.getAddress());
  fillDirections();
};
async function ensureChain(n) {
  const c = NETS[n]; const hex = '0x' + c.chainId.toString(16);
  try { await window.ethereum.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: hex }] }); }
  catch { await window.ethereum.request({ method: 'wallet_addEthereumChain', params: [{ chainId: hex, chainName: `${label(n)} testnet`, rpcUrls: [c.rpc], nativeCurrency: { name: c.native, symbol: c.native, decimals: 18 } }] }); }
  signer = await new ethers.BrowserProvider(window.ethereum).getSigner();
}
$('go').onclick = async () => {
  const d = directions().find((x) => x.key === $('dir').value); if (!d) return;
  try {
    await ensureChain(d.n);
    const gw = new ethers.Contract(NETS[d.n].gateway, GW_ABI, signer);
    const to = $('to').value.trim() || (await signer.getAddress());
    const v = ethers.parseEther($('amt').value || '0');
    const remoteId = NETS[NETS[d.n].remote].chainId;
    const tx = d.op === 'lock' ? await gw.lockNative(remoteId, to, { value: v, type: 0 }) : await gw.burnWrapped(remoteId, to, v, { type: 0 });
    $('msg').innerHTML = `sent ${short(tx.hash)} · the relayer delivers it after ${2} confirmations + 2-of-3 attestations`;
  } catch (e) { $('msg').textContent = e.shortMessage || e.message; }
};

fillDirections();
refresh();
setInterval(refresh, 20000);
