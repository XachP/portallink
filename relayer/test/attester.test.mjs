// Offline tests for the attester: it must only sign what the source chain actually emitted.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ethers } from 'ethers';
import { Attester } from '../attester.mjs';
import { GATEWAY_ABI, transferDigest, transferId, anvilKey } from '../lib.mjs';

const SRC_GW = '0x00000000000000000000000000000000000000a1';
const DST_GW = '0x00000000000000000000000000000000000000b2';
const iface = new ethers.Interface(GATEWAY_ABI());
const T = {
  srcChainId: 420420777, dstChainId: 31611, nonce: 7n, kind: 0,
  sender: '0x1111111111111111111111111111111111111111', recipient: '0x2222222222222222222222222222222222222222',
  amount: ethers.parseEther('3'),
};
const TX = '0x' + 'ab'.repeat(32);

function sentLog(t, { address = SRC_GW, id = transferId(t), index = 4 } = {}) {
  const ev = iface.getEvent('TransferSent');
  const enc = iface.encodeEventLog(ev, [id, t.dstChainId, t.nonce, t.kind, t.sender, t.recipient, t.amount]);
  return { address, topics: enc.topics, data: enc.data, transactionHash: TX, index, blockNumber: 100 };
}

function mk(logs, head = 105) {
  const a = new Attester(anvilKey(5), 'local');
  const prov = { getBlockNumber: async () => head, getLogs: async () => logs };
  a.providers = { 'local-portaldot': prov, 'local-mezo': prov };
  a.deployments = { 'local-portaldot': { gateway: SRC_GW }, 'local-mezo': { gateway: DST_GW } };
  return a;
}
const ptr = { src: 'local-portaldot', blockNumber: 100, txHash: TX, logIndex: 4 };

test('signs the EIP-712 digest for the destination gateway', async () => {
  const a = mk([sentLog(T)]);
  const r = await a.attest(ptr);
  assert.equal(r.dst, 'local-mezo');
  assert.equal(r.id, transferId(T));
  const signer = ethers.recoverAddress(transferDigest(T, DST_GW), r.signature);
  assert.equal(signer, a.address);
});

test('digest is bound to destination chain and gateway', () => {
  assert.notEqual(transferDigest(T, DST_GW), transferDigest(T, SRC_GW));
  assert.notEqual(transferDigest(T, DST_GW), transferDigest({ ...T, dstChainId: 1 }, DST_GW));
});

test('refuses logs from a contract other than the source gateway', async () => {
  const a = mk([sentLog(T, { address: '0x00000000000000000000000000000000000000ee' })]);
  await assert.rejects(a.attest(ptr), /not from source gateway/);
});

test('refuses when the event id does not match its fields (forged log)', async () => {
  const a = mk([sentLog(T, { id: ethers.ZeroHash })]);
  await assert.rejects(a.attest(ptr), /does not match/);
});

test('refuses a pointer to a log that does not exist', async () => {
  const a = mk([sentLog(T, { index: 9 })]);
  await assert.rejects(a.attest(ptr), /log not found/);
});

test('refuses before finality depth on chains that require it', async () => {
  const a = mk([sentLog(T)], 100);
  const { NETWORKS } = await import('../lib.mjs');
  const old = NETWORKS['local-portaldot'].confirmations;
  NETWORKS['local-portaldot'].confirmations = 2;
  try { await assert.rejects(a.attest(ptr), /not final/); } finally { NETWORKS['local-portaldot'].confirmations = old; }
});

test('refuses unknown destination chains', async () => {
  const bad = { ...T, dstChainId: 999 };
  const a = mk([sentLog(bad)]);
  await assert.rejects(a.attest(ptr), /unknown destination/);
});

test('JS transfer id equals Solidity abi.encode(TYPEHASH, ...) layout', () => {
  const typehash = ethers.id('Transfer(uint64 srcChainId,uint64 dstChainId,uint64 nonce,uint8 kind,address sender,address recipient,uint256 amount)');
  const manual = ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(
    ['bytes32', 'uint64', 'uint64', 'uint64', 'uint8', 'address', 'address', 'uint256'],
    [typehash, T.srcChainId, T.dstChainId, T.nonce, T.kind, T.sender, T.recipient, T.amount]));
  assert.equal(transferId(T), manual);
});
