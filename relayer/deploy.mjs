// Deploy + link PortalLink gateways.
//   node deploy.mjs --network <net> --remote <net> [--key-file f]   deploy gateway + wrapped token
//   node deploy.mjs --link --profile <profile>   [--key-file f]     configure routes both ways
// The deployer becomes admin + guardian (testnet). Attester addresses come from ATTESTER_KEYS
// (or ATTESTER_ADDRESSES=0x..,0x..,0x..) so secrets are never printed.
import { ethers } from 'ethers';
import {
  NETWORKS, LIMITS, artifact, provider, readKeyFile, saveDeployment, loadDeployment,
  networksForProfile, argv, log, anvilKey, fmt, sendAndWait,
} from './lib.mjs';

function attesterAddresses(profile) {
  if (process.env.ATTESTER_ADDRESSES) return process.env.ATTESTER_ADDRESSES.split(',').map((a) => ethers.getAddress(a.trim()));
  if (profile === 'local') return [5, 6, 7].map((i) => new ethers.Wallet(anvilKey(i)).address);
  return readKeyFile(process.env.ATTESTER_KEYS).map((k) => new ethers.Wallet(k).address);
}

function deployerKey(net) {
  if (NETWORKS[net].profile === 'local') return anvilKey(0);
  const f = argv('key-file') || process.env[`DEPLOYER_KEY_FILE_${net.toUpperCase().replace(/-/g, '_')}`] || process.env.DEPLOYER_KEY_FILE;
  if (!f) throw new Error(`pass --key-file <json> or DEPLOYER_KEY_FILE_${net.toUpperCase().replace(/-/g, '_')}`);
  return readKeyFile(f);
}

async function send(w, label, txReq) {
  const rc = await sendAndWait(w, txReq, label);
  log(`${label}: ${rc.hash}`);
  return rc;
}

/** Deploy, or reuse a matching contract already deployed (resume after a crash). */
async function deployContract(w, A, args, label, reuse) {
  const f = new ethers.ContractFactory(A.abi, A.bytecode, w);
  if (reuse) {
    log(`${label}: reusing ${reuse}`);
    return { address: reuse, rc: null };
  }
  const rc = await send(w, `deploy ${label}`, await f.getDeployTransaction(...args));
  return { address: ethers.getAddress(rc.contractAddress), rc };
}

async function deploy(net, remote) {
  const n = NETWORKS[net];
  const r = NETWORKS[remote];
  const prov = provider(net);
  const w = new ethers.Wallet(deployerKey(net), prov);
  const bal = await prov.getBalance(w.address);
  log(`deploying on ${net} (chain ${n.chainId}) from ${w.address}, balance ${fmt(bal, n.native)}`);
  if (bal === 0n) throw new Error('deployer has no gas');
  const attesters = attesterAddresses(n.profile);
  const T = artifact('WrappedToken');
  const G = artifact('PortalGateway');
  const reuseToken = argv('reuse-token');
  const token = await deployContract(w, T, [r.wrappedName, r.wrappedSymbol, r.chainId], `WrappedToken ${r.wrappedSymbol}`, reuseToken);
  const gw = await deployContract(w, G, [w.address, w.address, attesters, 2], 'PortalGateway', argv('reuse-gateway'));
  const tokenC = new ethers.Contract(token.address, T.abi, w);
  const bindRc = await send(w, 'bindGateway', await tokenC.bindGateway.populateTransaction(gw.address));
  const after = await prov.getBalance(w.address);
  const blocks = [token.rc?.blockNumber, gw.rc?.blockNumber, bindRc.blockNumber].filter(Boolean);
  saveDeployment(net, {
    network: net, chainId: n.chainId, native: n.native,
    gateway: gw.address, wrapped: token.address, wrappedSymbol: r.wrappedSymbol,
    wrappedOriginChainId: r.chainId, remote, attesters, threshold: 2, admin: w.address, guardian: w.address,
    block: Math.min(...blocks),
    txs: { wrappedToken: token.rc?.hash ?? argv('reuse-token-tx', null), gateway: gw.rc?.hash, bindGateway: bindRc.hash },
    cost: ethers.formatEther(bal - after), deployedAt: new Date().toISOString(), links: {},
  });
  log(`saved deploy/${net}.json  (spent ${fmt(bal - after, n.native)})`);
}

async function link(profile) {
  const nets = networksForProfile(profile).filter((x) => loadDeployment(x));
  if (nets.length < 2) throw new Error('deploy both sides first');
  const G = artifact('PortalGateway');
  for (const net of nets) {
    const dep = loadDeployment(net);
    const remote = loadDeployment(dep.remote);
    if (!remote) continue;
    const prov = provider(net);
    const w = new ethers.Wallet(deployerKey(net), prov);
    const gw = new ethers.Contract(dep.gateway, G.abi, w);
    const [peer] = await gw.route(remote.chainId);
    if (peer !== ethers.ZeroAddress) { log(`${net}: route to ${dep.remote} already set (${peer})`); continue; }
    const cfg = (sym) => LIMITS[sym].map((v) => ethers.parseEther(v));
    const rc = await send(w, `${net} configureRoute -> ${dep.remote}`,
      await gw.configureRoute.populateTransaction(remote.chainId, remote.gateway, dep.wrapped, cfg(dep.native), cfg(remote.native)));
    dep.txs.configureRoute = rc.hash;
    dep.peer = remote.gateway;
    saveDeployment(net, dep);
  }
}

if (argv('link')) await link(argv('profile', 'local'));
else {
  const net = argv('network');
  const remote = argv('remote');
  if (!NETWORKS[net] || !NETWORKS[remote]) throw new Error('usage: --network <net> --remote <net>');
  await deploy(net, remote);
}
