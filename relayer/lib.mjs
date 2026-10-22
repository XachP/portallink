// Shared helpers for the PortalLink deployer, attesters and relayer.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { ethers } from 'ethers';

export const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

/** Every chain PortalLink knows about. `profile` groups chains that are bridged together. */
export const NETWORKS = {
  'portaldot-testnet': {
    profile: 'testnet', chainId: 420420777, rpc: 'https://test-evm-rpc-v3.portaldot.dev',
    native: 'tPOT', wrappedName: 'PortalLink Wrapped tPOT', wrappedSymbol: 'wPOT',
    explorer: 'https://node-console.portaldot.dev', confirmations: 2, logChunk: 1000,
    // pallet-revive: eth_getTransactionReceipt drops older txs; logs by block stay queryable.
    receiptsArePruned: true,
  },
  'mezo-testnet': {
    profile: 'testnet', chainId: 31611, rpc: 'https://rpc.test.mezo.org',
    native: 'BTC', wrappedName: 'PortalLink Wrapped Mezo BTC', wrappedSymbol: 'wBTC.m',
    explorer: 'https://explorer.test.mezo.org', confirmations: 2, logChunk: 5000,
  },
  'local-portaldot': {
    profile: 'local', chainId: 420420777, rpc: 'http://127.0.0.1:8545',
    native: 'tPOT', wrappedName: 'PortalLink Wrapped tPOT', wrappedSymbol: 'wPOT',
    explorer: '', confirmations: 0, logChunk: 10000,
  },
  'local-mezo': {
    profile: 'local', chainId: 31611, rpc: 'http://127.0.0.1:8546',
    native: 'BTC', wrappedName: 'PortalLink Wrapped Mezo BTC', wrappedSymbol: 'wBTC.m',
    explorer: '', confirmations: 0, logChunk: 10000,
  },
};

/** Per-asset route limits in 18-decimal EVM units: [min, maxPerTransfer, windowCap per 24h]. */
export const LIMITS = {
  tPOT: ['0.2', '5000', '50000'], // revive ED is 0.1 tPOT; stay above it
  BTC: ['0.00001', '0.01', '0.05'],
};

export const KIND = ['NativeLocked', 'WrappedBurned'];

export const TRANSFER_TYPES = {
  Transfer: [
    { name: 'srcChainId', type: 'uint64' },
    { name: 'dstChainId', type: 'uint64' },
    { name: 'nonce', type: 'uint64' },
    { name: 'kind', type: 'uint8' },
    { name: 'sender', type: 'address' },
    { name: 'recipient', type: 'address' },
    { name: 'amount', type: 'uint256' },
  ],
};

export function networksForProfile(profile) {
  return Object.entries(NETWORKS).filter(([, n]) => n.profile === profile).map(([k]) => k);
}

export function artifact(name) {
  const p = path.join(ROOT, 'out', `${name}.sol`, `${name}.json`);
  if (!fs.existsSync(p)) throw new Error(`missing ${p}: run "forge build" first`);
  const j = JSON.parse(fs.readFileSync(p, 'utf8'));
  return { abi: j.abi, bytecode: j.bytecode.object };
}

export const GATEWAY_ABI = () => artifact('PortalGateway').abi;
export const TOKEN_ABI = () => artifact('WrappedToken').abi;

export function deploymentPath(network) {
  return path.join(ROOT, 'deploy', `${network}.json`);
}

export function loadDeployment(network) {
  const p = deploymentPath(network);
  return fs.existsSync(p) ? JSON.parse(fs.readFileSync(p, 'utf8')) : null;
}

export function saveDeployment(network, data) {
  fs.mkdirSync(path.dirname(deploymentPath(network)), { recursive: true });
  fs.writeFileSync(deploymentPath(network), JSON.stringify(data, null, 2) + '\n');
}

export function provider(network) {
  const n = NETWORKS[network];
  if (!n) throw new Error(`unknown network ${network}`);
  return new ethers.JsonRpcProvider(process.env[`RPC_${network.toUpperCase().replace(/-/g, '_')}`] || n.rpc,
    n.chainId, { staticNetwork: true, batchMaxCount: 1 });
}

/**
 * Load a private key from a JSON key file without ever printing it.
 * Supports: {privateKey}, {evm:{privateKey}}, cast-wallet output {data:[{private_key}]},
 * and {attesters:[{privateKey}]} (returns the array).
 */
export function readKeyFile(file) {
  const j = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (Array.isArray(j.attesters)) return j.attesters.map((a) => a.privateKey);
  if (j.privateKey) return j.privateKey;
  if (j.evm?.privateKey) return j.evm.privateKey;
  const d = Array.isArray(j.data) ? j.data[0] : j.data;
  if (d?.private_key) return d.private_key;
  throw new Error(`no private key found in ${file}`);
}

/** Anvil's public dev mnemonic. ONLY used for the local profile. */
export const ANVIL_MNEMONIC = 'test test test test test test test test test test test junk';
export function anvilKey(i) {
  return ethers.HDNodeWallet.fromPhrase(ANVIL_MNEMONIC, undefined, `m/44'/60'/0'/0/${i}`).privateKey;
}

export function domain(chainId, gateway) {
  return { name: 'PortalLink', version: '1', chainId, verifyingContract: gateway };
}

export function transferDigest(t, gateway) {
  return ethers.TypedDataEncoder.hash(domain(t.dstChainId, gateway), TRANSFER_TYPES, t);
}

export function transferId(t) {
  return ethers.TypedDataEncoder.hashStruct('Transfer', TRANSFER_TYPES, t);
}

/** Legacy (type-0) txs work on both pallet-revive eth-rpc and Mezo. */
export async function txOverrides(prov) {
  const fee = await prov.getFeeData();
  return { type: 0, gasPrice: fee.gasPrice };
}

export function fmt(wei, symbol) {
  const s = ethers.formatEther(wei);
  return `${s.includes('.') ? s.replace(/\.?0+$/, '') : s} ${symbol}`;
}

export function argv(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  if (i === -1) return fallback;
  const v = process.argv[i + 1];
  return v === undefined || v.startsWith('--') ? true : v;
}

export const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);

/**
 * Wait for a receipt using raw JSON-RPC. ethers' own wait() loops forever on Mezo because its
 * receipts omit effectiveGasPrice ("report this; could not find tx or effectiveGasPrice").
 */
export async function waitTx(prov, hash, { timeoutMs = 240_000, pollMs = 2_000 } = {}) {
  const end = Date.now() + timeoutMs;
  while (Date.now() < end) {
    const r = await prov.send('eth_getTransactionReceipt', [hash]).catch(() => null);
    if (r) {
      return {
        hash, status: Number(r.status), blockNumber: Number(r.blockNumber), contractAddress: r.contractAddress,
        gasUsed: BigInt(r.gasUsed), logs: r.logs.map((l) => ({ ...l, index: Number(l.logIndex), blockNumber: Number(l.blockNumber) })),
      };
    }
    await new Promise((res) => setTimeout(res, pollMs));
  }
  throw new Error(`timed out waiting for ${hash}`);
}

/** Sign + send a populated tx and wait for its receipt (portable across revive and Mezo). */
export async function sendAndWait(wallet, txReq, label) {
  const ov = await txOverrides(wallet.provider);
  const sent = await wallet.sendTransaction({ ...txReq, ...ov });
  const rc = await waitTx(wallet.provider, sent.hash);
  if (rc.status !== 1) throw new Error(`${label || 'tx'} reverted: ${sent.hash}`);
  return rc;
}
