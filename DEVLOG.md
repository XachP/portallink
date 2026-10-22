# Development log

Times are US Central (CDT).

## 2026-10-21

* Probed Portaldot V3 testnet live.
  * Runtime pallets: `revive` with `allowEVMBytecode=true`, `contracts`, `assets`, `nfts`, `oracle`, and the custom `registrarPara` / `registrarRelay`. No XCM, ISMP or iBridge.
  * ecrecover/sha256 precompiles work through the eth-rpc.
  * Native accounts map to `h160 ++ 0xEE×12` (`reviveApi.accountId`).
  * Storage deposit is 0.06 tPOT/byte.
* Reviewed the 10 existing Hacker House builds. None target Multi-Chain & Cross-Chain Infra, and the FAQ lists bridging and adapters as missing. So: PortalLink.
* Contracts:
  * `PortalGateway` with lock/mint and burn/release;
  * `AttesterSet` (2-of-3 EIP-712, rotation);
  * `WrappedToken`.
* Tests: 49 Foundry tests, including a stateful invariant (wrapped supply equals escrow).
* Fix: split route limits into native vs wrapped. A single bound was wrong for tPOT vs BTC.
* Relayer, independent attesters, deployer, user CLI, and a solvency checker. Local two-chain e2e on anvil.
* Found that Mezo receipts lack `effectiveGasPrice`, which makes ethers `wait()` hang. Switched to raw receipt polling.
* **Mezo testnet:** deployed wPOT (`0x0B4a…Bbfc`, tx `0x46ab401f…d078`) and PortalGateway (`0xA86c…01FB`, tx `0x23d13978…714f`), bound (tx `0xd5a950e9…fc9b6`). Both verified on Sourcify.
* Portaldot deploy cost measured at about 198 + 833 tPOT. Wrote `portaldot-go-live.sh` to run the moment the faucet pays.
* Dashboard on GitHub Pages: live chain cards, solvency, transfers, wallet form.

## Next

* Portaldot deployment and the live round trip (waiting on the hackathon faucet).
* Attester HTTP services on separate hosts; demo video; pitch deck.
* WASM (ink!) lane prototype; pallet-assets lane design.
