// Move faucet tPOT from the native (sr25519, "5...") ticket account to the EVM deployer's
// pallet-revive mapped account, so the 0x key can pay gas + storage deposits.
//   node portaldot-fund.mjs --wallet ../../wallet/portaldot_test.json [--min 50] [--reserve 1] [--wait]
// Exit 0 = funded (or already funded), 3 = still waiting for the faucet.
import fs from 'node:fs';
import { ApiPromise, WsProvider } from '@polkadot/api';
import { Keyring } from '@polkadot/keyring';
import { cryptoWaitReady } from '@polkadot/util-crypto';
import { ethers } from 'ethers';
import { argv, log, provider } from './lib.mjs';

const WS = process.env.PORTALDOT_WS || 'wss://test-node-v3.portaldot.dev';
const UNIT = 10n ** 14n; // native tPOT has 14 decimals; the EVM view scales to 18
const walletFile = argv('wallet');
if (!walletFile) throw new Error('--wallet <portaldot_test.json> required');
const w = JSON.parse(fs.readFileSync(walletFile, 'utf8'));
const min = BigInt(Math.round(Number(argv('min', 50)) * 1e6)) * UNIT / 1_000_000n;
const reserve = BigInt(Math.round(Number(argv('reserve', 1)) * 1e6)) * UNIT / 1_000_000n;
const evmAddr = new ethers.Wallet(w.evm.privateKey).address;

await cryptoWaitReady();
const api = await ApiPromise.create({ provider: new WsProvider(WS), noInitWarn: true });
const pair = new Keyring({ type: 'sr25519', ss58Format: 42 }).addFromMnemonic(w.native.mnemonic);
if (pair.address !== w.native.address) throw new Error('wallet file mismatch');
const mapped = (await api.call.reviveApi.accountId(evmAddr)).toString();
const fmt14 = (v) => `${(Number(v) / 1e14).toLocaleString('en-US', { maximumFractionDigits: 4 })} tPOT`;

async function balances() {
  const [n, m] = await Promise.all([api.query.system.account(pair.address), api.query.system.account(mapped)]);
  return { native: n.data.free.toBigInt(), mapped: m.data.free.toBigInt() };
}

let b = await balances();
log(`native ${pair.address}: ${fmt14(b.native)} | EVM ${evmAddr} (mapped ${mapped}): ${fmt14(b.mapped)}`);
while (b.native < min + reserve && b.mapped < min) {
  if (!argv('wait')) { log(`waiting for faucet: need >= ${fmt14(min + reserve)} on ${pair.address}`); await api.disconnect(); process.exit(3); }
  await new Promise((r) => setTimeout(r, 60_000));
  b = await balances();
  log(`native ${fmt14(b.native)} | mapped ${fmt14(b.mapped)}`);
}

if (b.native >= min + reserve) {
  const probe = api.tx.balances.transferKeepAlive(mapped, b.native - reserve);
  const { partialFee } = await probe.paymentInfo(pair);
  const amount = b.native - reserve - partialFee.toBigInt() * 2n;
  log(`transferring ${fmt14(amount)} -> ${mapped}`);
  const hash = await new Promise((resolve, reject) => {
    api.tx.balances.transferKeepAlive(mapped, amount).signAndSend(pair, ({ status, dispatchError, txHash }) => {
      if (dispatchError) reject(new Error(dispatchError.toString()));
      if (status.isInBlock) resolve({ txHash: txHash.toHex(), block: status.asInBlock.toHex() });
    }).catch(reject);
  });
  log(`substrate transfer ${hash.txHash} in block ${hash.block}`);
  fs.mkdirSync('../deploy', { recursive: true });
  fs.writeFileSync('../deploy/portaldot-funding.json', JSON.stringify({ from: pair.address, to: mapped, evm: evmAddr, amount: amount.toString(), ...hash, at: new Date().toISOString() }, null, 2) + '\n');
}
const evmBal = await provider('portaldot-testnet').getBalance(evmAddr);
log(`EVM balance of ${evmAddr}: ${ethers.formatEther(evmBal)} tPOT`);
await api.disconnect();
