# PortalLink threat model

Scope: `PortalGateway`, `AttesterSet`, `WrappedToken`, and the off-chain attesters and relayer, as deployed on Portaldot V3 testnet (pallet-revive) and Mezo testnet. **Testnet only, not audited.**

## Trust assumptions

| Actor | Trusted for | Not trusted for |
|---|---|---|
| Attester committee (2-of-3) | Safety: a majority attests only to logs that really happened | Draining more than a route's escrow; minting past the rate window |
| Relayer | Nothing. It is permissionless, anyone can deliver, and it can't alter a signed transfer | — |
| Admin | Configuring routes once, tuning limits, unpausing | Moving user funds (there is no admin withdraw); rewriting peers (write-once) |
| Guardian | Pausing quickly | Unpausing or configuring |
| Source chain RPC | Each attester uses its own. A lying RPC only fools the attesters that use it | — |

In the hackathon deployment, **one operator runs all three attester keys**. This is stated openly and is the main centralisation point. The design supports separate operators today (`attester.mjs --serve` plus `ATTESTER_URLS`).

## Assets at risk

* The tPOT escrowed in the Portaldot gateway (`lockedOut[route]`).
* The BTC escrowed in the Mezo gateway.
* The integrity of wPOT and wBTC.m supply. Holders must be able to redeem 1:1.

## Threats and mitigations

| # | Threat | Mitigation | Test |
|---|---|---|---|
| T1 | Forged transfer (no real lock) | `threshold` distinct attester signatures over EIP-712. Attesters rebuild the struct from the source log themselves and check the emitter, finality and id | `test_RevertWhen_OnlyOneSignature`, `test_RevertWhen_UnknownSigner`, relayer `refuses logs from a contract other than the source gateway`, `refuses when the event id does not match` |
| T2 | Replay on the same destination | `processed[id]` set before effects | `test_RevertWhen_Replayed` |
| T3 | Replay on another chain or gateway | Domain = (`PortalLink`, `1`, `block.chainid`, gateway address); `dstChainId` checked | `test_RevertWhen_WrongDestinationChain`, `test_RevertWhen_SignaturesForAnotherGateway`, `test_DomainSeparatorBindsChainAndContract` |
| T4 | Duplicate signer counted twice | Recovered signers must be strictly ascending | `test_RevertWhen_SameSignerTwice`, `test_RevertWhen_SignaturesUnsorted` |
| T5 | Signature malleability | `s <= n/2`, `v ∈ {27,28}`, length exactly 65 | `test_RevertWhen_MalleableHighS`, `test_RevertWhen_SignatureLengthWrong` |
| T6 | Tampered amount or recipient | Any field change changes the digest, so the recovered signer is unknown | `test_RevertWhen_TamperedAmount` |
| T7 | **Committee compromise (2 keys)** | Releases are capped at `lockedOut[route]`, so the loss is bounded by escrow; a 24h inbound cap per asset bounds wrapped mints; the guardian can pause; rotation needs the current majority | `test_RevertWhen_ReleaseExceedsEscrow_EvenWithValidSigs`, `test_RateLimit_ThenWindowResets`, `test_GuardianPauses_OnlyAdminUnpauses` |
| T8 | Re-entrancy during the native payout | `nonReentrant`, state written before the call, 50k-gas push with no returndata copy; failures parked in `owed` | `test_ReentrantRecipient_CannotDoubleWithdraw` |
| T9 | Griefing by a recipient that reverts | Payout parked, relay tx succeeds, recipient later calls `withdrawOwed()` | `test_RevertingRecipient_PayoutParked_ThenWithdrawn` |
| T10 | Wrapped supply drifts from escrow | Mint only via attested NativeLocked; burn emits WrappedBurned; checked by the stateful invariant | `invariant_WrappedFullyBacked`, `invariant_GhostAccounting`, `status.mjs` exit code 2 |
| T11 | Admin redirects a route to a malicious peer | Peers are write-once; there is no admin withdraw path | `test_RoutesAreWriteOnce` |
| T12 | Admin key typo or loss | 2-step `proposeAdmin` / `acceptAdmin` | `test_AdminTransferIsTwoStep` |
| T13 | Unbounded or minority committee | `0 < t`, `t > n/2`, `n ≤ 16`, no zero or duplicate members | `test_RevertWhen_MinorityThreshold`, `test_RevertWhen_DuplicateOrZeroAttester`, `test_RevertWhen_TooManyAttesters` |
| T14 | Reorg after attestation | Attesters wait `confirmations` blocks per chain before signing | relayer `refuses before finality depth` |
| T15 | Dust below the existential deposit on revive | Minimum transfer is 0.2 tPOT (ED is 0.1) | config `LIMITS` |
| T16 | Relayer goes down | Liveness only. Anyone can run `relayer.mjs`, and signed transfers never expire | — |
| T17 | Pruned receipts on Portaldot eth-rpc | Attesters verify via `eth_getLogs` by block, not receipts | — |

## Known limitations

* The committee is a trusted majority. A light-client upgrade (BEEFY/MMR, whose pallets exist in the Portaldot runtime) is on the roadmap.
* All three testnet attester keys are held by one operator.
* There are no fees, so there is no economic incentive to relay (fine for a testnet).
* Rate-limit windows use `block.timestamp`, so validators can skew them by seconds. That is acceptable for a 24h window.
* Mezo and Portaldot finality assumptions use simple confirmation depth.
* No formal audit.

## Responsible disclosure

Open a GitHub issue marked `security` (testnet only, no bounty).
