// Solvency + route status for every deployed chain in a profile.
//   node status.mjs --profile testnet [--json]
import { ethers } from 'ethers';
import { NETWORKS, GATEWAY_ABI, TOKEN_ABI, loadDeployment, provider, networksForProfile, argv, fmt } from './lib.mjs';

const profile = argv('profile', 'local');
const out = { profile, checkedAt: new Date().toISOString(), chains: {}, routes: [] };
const nets = networksForProfile(profile).filter((x) => loadDeployment(x));
for (const net of nets) {
  const dep = loadDeployment(net);
  const prov = provider(net);
  const gw = new ethers.Contract(dep.gateway, GATEWAY_ABI(), prov);
  const tok = new ethers.Contract(dep.wrapped, TOKEN_ABI(), prov);
  const remote = loadDeployment(dep.remote);
  const [, , lockedOut] = remote ? await gw.route(remote.chainId) : [0, 0, 0n];
  out.chains[net] = {
    chainId: dep.chainId, gateway: dep.gateway, escrowBalance: (await prov.getBalance(dep.gateway)).toString(),
    lockedOut: lockedOut.toString(), totalOwed: (await gw.totalOwed()).toString(), paused: await gw.paused(),
    wrappedSymbol: dep.wrappedSymbol, wrappedSupply: (await tok.totalSupply()).toString(), native: dep.native,
    head: await prov.getBlockNumber(),
  };
}
for (const net of nets) {
  const a = out.chains[net];
  const dep = loadDeployment(net);
  const b = out.chains[dep.remote];
  if (!b) continue;
  // native escrowed on A for route A->B must cover every wrapped A-coin on B
  const backed = BigInt(a.lockedOut) >= BigInt(b.wrappedSupply) && BigInt(a.escrowBalance) >= BigInt(a.lockedOut) + BigInt(a.totalOwed);
  out.routes.push({ from: net, to: dep.remote, escrowed: a.lockedOut, wrappedOnRemote: b.wrappedSupply, asset: a.native, wrappedSymbol: b.wrappedSymbol, fullyBacked: backed });
}
if (argv('json')) console.log(JSON.stringify(out, null, 2));
else for (const r of out.routes) console.log(`${r.from} -> ${r.to}: escrowed ${fmt(r.escrowed, r.asset)} | ${r.wrappedSymbol} on ${r.to}: ${fmt(r.wrappedOnRemote, r.wrappedSymbol)} | ${r.fullyBacked ? 'FULLY BACKED' : 'UNDER-COLLATERALISED'}`);
process.exit(out.routes.every((r) => r.fullyBacked) ? 0 : 2);
