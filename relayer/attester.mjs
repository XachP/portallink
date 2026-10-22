// PortalLink attester.
//
// An attester never trusts the relayer's description of a transfer. Given only a pointer
// (source network, block number, tx hash, log index) it re-reads the log from ITS OWN RPC,
// checks it was emitted by the configured source gateway, checks finality depth, rebuilds the
// Transfer struct and signs the EIP-712 digest for the configured destination gateway.
//
// Run in-process (relayer loads keys) or as an HTTP service on its own machine:
//   node attester.mjs --serve --profile testnet --index 0 --keys ../.secrets/attesters.json --port 7001
import http from 'node:http';
import { ethers } from 'ethers';
import {
  NETWORKS, GATEWAY_ABI, loadDeployment, provider, transferDigest, transferId, readKeyFile, argv, log,
  networksForProfile, anvilKey,
} from './lib.mjs';

export class Attester {
  constructor(privateKey, profile) {
    this.wallet = new ethers.Wallet(privateKey);
    this.address = this.wallet.address;
    this.profile = profile;
    this.iface = new ethers.Interface(GATEWAY_ABI());
    this.providers = {};
    this.deployments = {};
    for (const n of networksForProfile(profile)) {
      this.providers[n] = provider(n);
      this.deployments[n] = loadDeployment(n);
    }
  }

  networkByChainId(chainId) {
    return Object.keys(this.providers).find((n) => BigInt(NETWORKS[n].chainId) === BigInt(chainId));
  }

  /** @returns {{signer, signature, transfer, id}} */
  async attest({ src, blockNumber, txHash, logIndex }) {
    const srcDep = this.deployments[src];
    if (!srcDep) throw new Error(`no deployment for ${src}`);
    const prov = this.providers[src];
    const head = await prov.getBlockNumber();
    if (head - Number(blockNumber) < NETWORKS[src].confirmations) throw new Error('not final yet');

    const logs = await prov.getLogs({ address: srcDep.gateway, fromBlock: Number(blockNumber), toBlock: Number(blockNumber) });
    const raw = logs.find((l) => l.transactionHash.toLowerCase() === txHash.toLowerCase() && Number(l.index) === Number(logIndex));
    if (!raw) throw new Error('log not found at that position');
    if (raw.address.toLowerCase() !== srcDep.gateway.toLowerCase()) throw new Error('log not from source gateway');
    const ev = this.iface.parseLog(raw);
    if (ev?.name !== 'TransferSent') throw new Error('not a TransferSent log');

    const dst = this.networkByChainId(ev.args.dstChainId);
    if (!dst || !this.deployments[dst]) throw new Error(`unknown destination chain ${ev.args.dstChainId}`);
    const transfer = {
      srcChainId: NETWORKS[src].chainId,
      dstChainId: Number(ev.args.dstChainId),
      nonce: ev.args.nonce,
      kind: Number(ev.args.kind),
      sender: ev.args.sender,
      recipient: ev.args.recipient,
      amount: ev.args.amount,
    };
    const id = transferId(transfer);
    if (id !== ev.args.id) throw new Error('event id does not match rebuilt transfer');
    const digest = transferDigest(transfer, this.deployments[dst].gateway);
    const signature = this.wallet.signingKey.sign(digest).serialized;
    return { signer: this.address, signature, transfer: serial(transfer), id, dst };
  }
}

const serial = (t) => Object.fromEntries(Object.entries(t).map(([k, v]) => [k, typeof v === 'bigint' ? v.toString() : v]));

/** Attester reached over HTTP (one per operator in a real deployment). */
export class RemoteAttester {
  constructor(url) { this.url = url; this.address = null; }
  async attest(ptr) {
    const r = await fetch(`${this.url}/attest`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(ptr) });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || `attester ${this.url} ${r.status}`);
    this.address = j.signer;
    return j;
  }
}

export function loadAttesters(profile) {
  if (process.env.ATTESTER_URLS) return process.env.ATTESTER_URLS.split(',').map((u) => new RemoteAttester(u.trim()));
  if (profile === 'local') return [5, 6, 7].map((i) => new Attester(anvilKey(i), profile));
  const file = process.env.ATTESTER_KEYS;
  if (!file) throw new Error('set ATTESTER_KEYS=<json file> or ATTESTER_URLS=<url,url,url>');
  return readKeyFile(file).map((k) => new Attester(k, profile));
}

if (process.argv[1]?.endsWith('attester.mjs') && argv('serve')) {
  const profile = argv('profile', 'testnet');
  const idx = Number(argv('index', 0));
  const keys = profile === 'local' ? [5, 6, 7].map(anvilKey) : readKeyFile(argv('keys'));
  const a = new Attester(keys[idx], profile);
  const port = Number(argv('port', 7001 + idx));
  http.createServer(async (req, res) => {
    const send = (code, body) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)); };
    if (req.method === 'GET' && req.url === '/health') return send(200, { signer: a.address, profile });
    if (req.method !== 'POST' || req.url !== '/attest') return send(404, { error: 'not found' });
    let body = '';
    req.on('data', (c) => { body += c; if (body.length > 4096) req.destroy(); });
    req.on('end', async () => {
      try { send(200, await a.attest(JSON.parse(body))); } catch (e) { send(400, { error: e.message }); }
    });
  }).listen(port, '127.0.0.1', () => log(`attester ${a.address} listening on 127.0.0.1:${port}`));
}
