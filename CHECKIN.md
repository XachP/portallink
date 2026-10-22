# Portaldot Hacker House 2026: check-in (due Fri Oct 24, 12:00 UTC / 7:00 AM CDT)

**Project:** PortalLink
**Track:** Multi-Chain & Cross-Chain Infra
**Team:** Zachary Plumey (solo) · GitHub XachP · Discord xachp · Telegram @XachPXP

**One-liner:** a verifiable lock/mint bridge for Portaldot V3. Native tPOT on revive ⇄ wPOT on Mezo testnet, and Mezo BTC ⇄ wBTC.m on Portaldot. A 2-of-3 attester committee approves each transfer, releases are capped by escrow, and a live solvency dashboard shows the state.

## Current progress
* **Contracts done** (Solidity, built for revive):
  * `PortalGateway`: lock/mint and burn/release, per-asset limits, 24h rate windows, guardian pause, parked payouts, write-once peers, 2-step admin.
  * `AttesterSet`: 2-of-3 EIP-712 committee with self-governed rotation.
  * `WrappedToken`: minimal ERC-20.
* **Tests:** 49 Foundry tests (unit, fuzz, and a stateful invariant that wrapped supply always equals escrow) plus 8 relayer tests. Coverage: AttesterSet 100% of lines, PortalGateway 97%.
* **Off-chain done:**
  * attesters that independently re-read source logs before signing (in-process or HTTP);
  * permissionless relayer;
  * deployer;
  * user CLI;
  * solvency checker;
  * Substrate funding script (`@polkadot/api`, revive account mapping).
* **Working end-to-end locally:** two chains (420420777 and 31611) running lock → mint → burn → release plus the reverse BTC route (`scripts/local-e2e.sh`).
* **Mezo testnet side deployed and verified on Sourcify.**
* **Portaldot side:** deploy cost measured on the live V3 testnet (about 1,030 tPOT of storage deposit). The deploy script is ready to run once the faucet pays.
* **Dashboard live:** GitHub Pages reads both chains from public RPCs.

## Outstanding items
1. Portaldot V3 deployment, linking, and the live round trip. This is waiting on test tPOT; a ticket is open for `5CkhvT3R41qgHD1uEvaAbf1Es1vftXJUwKtw2qy33QPcZuyz`.
2. Run the attesters as separate HTTP services on separate hosts.
3. Demo video (3 minutes or less) and pitch deck.
4. WASM (ink!) lane prototype through Portaldot's `contracts` VM.
5. Design for a pallet-assets lane (multisig custody on the Substrate side).

## Public GitHub repository
https://github.com/XachP/portallink
* Complete README with architecture and sequence diagrams (mermaid, also in `docs/img/`).
* THREAT_MODEL.md.
* DEVLOG.md (development records).
* CI workflow.
* MIT license.

## Testnet deployment information
| Chain | Contract | Address | Tx |
|---|---|---|---|
| Mezo testnet (31611) | PortalGateway | 0xA86c25550eb58B6c7FB3cd4350CEBFd0FA9801FB | 0x23d139789ec5ada9186c392f0f785e8848e29a20ddb65aa66061aa896644714f |
| Mezo testnet (31611) | wPOT (WrappedToken) | 0x0B4a82bCD88FA31cB71E895290251f855f6ABbfc | 0x46ab401fef8047b749ceffb5eb0dd73cbbb720ddaecf1746d90996aee5ead078 |
| Mezo testnet (31611) | bindGateway | — | 0xd5a950e9f3dfc01c72414cc9f733d9480c9bf71acb56fb6b80997050497fc9b6 |
| Portaldot V3 (420420777) | PortalGateway + wBTC.m | _to be filled in by scripts/portaldot-go-live.sh_ | _to be filled in_ |

Explorer: https://explorer.test.mezo.org/address/0xA86c25550eb58B6c7FB3cd4350CEBFd0FA9801FB. For Portaldot, use the node console at https://node-console.portaldot.dev (there's no EVM explorer yet).

## Initial demo
* Live dashboard: https://xachp.github.io/portallink/
* Reproducible local demo: `./scripts/local-e2e.sh` (output is in the README).
* A video of 3 minutes or less will follow with the Portaldot live round trip.
