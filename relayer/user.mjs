// User-side actions (what the dashboard wallet buttons do), for scripts and demos.
//   node user.mjs lock --network portaldot-testnet --amount 1 --to 0x..   (lock native, mint wrapped remotely)
//   node user.mjs burn --network mezo-testnet --amount 1 --to 0x..        (burn wrapped, release remotely)
import { ethers } from 'ethers';
import { NETWORKS, GATEWAY_ABI, TOKEN_ABI, loadDeployment, provider, readKeyFile, argv, log, anvilKey, fmt, sendAndWait } from './lib.mjs';

const action = process.argv[2];
const net = argv('network');
const dep = loadDeployment(net);
if (!dep) throw new Error(`no deployment for ${net}`);
const n = NETWORKS[net];
const prov = provider(net);
const key = n.profile === 'local' ? anvilKey(Number(argv('account', 2))) : readKeyFile(argv('key-file', process.env.USER_KEY_FILE));
const w = new ethers.Wallet(key, prov);
const gw = new ethers.Contract(dep.gateway, GATEWAY_ABI(), w);
const to = argv('to', w.address);
const remote = loadDeployment(dep.remote);
const amount = ethers.parseEther(String(argv('amount', '1')));

let tx;
if (action === 'lock') {
  log(`lock ${fmt(amount, n.native)} on ${net} -> ${remote.wrappedSymbol ?? 'wrapped'} on ${dep.remote} for ${to}`);
  tx = await gw.lockNative.populateTransaction(remote.chainId, to, { value: amount });
} else if (action === 'burn') {
  const token = new ethers.Contract(dep.wrapped, TOKEN_ABI(), w);
  log(`burn ${fmt(amount, dep.wrappedSymbol)} on ${net} (balance ${fmt(await token.balanceOf(w.address), dep.wrappedSymbol)}) -> release ${remote.native} on ${dep.remote} for ${to}`);
  tx = await gw.burnWrapped.populateTransaction(remote.chainId, to, amount);
} else {
  console.error('usage: node user.mjs lock|burn --network <net> --amount <n> [--to 0x..]');
  process.exit(1);
}
const rc = await sendAndWait(w, tx, action);
const ev = rc.logs.map((l) => { try { return gw.interface.parseLog(l); } catch { return null; } }).find((e) => e?.name === 'TransferSent');
log(`tx ${rc.hash} block ${rc.blockNumber} transfer id ${ev?.args.id} nonce ${ev?.args.nonce}`);
console.log(JSON.stringify({ tx: rc.hash, block: rc.blockNumber, id: ev?.args.id }));
