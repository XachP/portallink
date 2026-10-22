#!/usr/bin/env bash
# Full local round trip on two anvil chains that mimic Portaldot (420420777) and Mezo (31611):
# deploy -> link -> relayer -> lock tPOT -> wPOT minted -> burn wPOT -> tPOT released
# -> reverse route (lock BTC -> wBTC.m minted) -> solvency check.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"
LOG=${LOG:-/tmp/portallink-e2e}; mkdir -p "$LOG"
cleanup() { kill ${PIDS:-} 2>/dev/null || true; }
trap cleanup EXIT

forge build --quiet
anvil --chain-id 420420777 --port 8545 --block-time 1 --silent & PIDS="$!"
anvil --chain-id 31611 --port 8546 --block-time 1 --silent & PIDS="$PIDS $!"
sleep 2
rm -f deploy/local-*.json relayer/state-local.json docs/data/local-feed.json

cd relayer
node deploy.mjs --network local-portaldot --remote local-mezo
node deploy.mjs --network local-mezo --remote local-portaldot
node deploy.mjs --link --profile local
POLL_MS=1000 node relayer.mjs --profile local > "$LOG/relayer.log" 2>&1 & PIDS="$PIDS $!"

BOB=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC   # anvil account 2 (the "user")
wait_for() { for _ in $(seq 1 30); do grep -q "$1" "$LOG/relayer.log" && return 0; sleep 1; done; echo "timeout waiting for $1"; cat "$LOG/relayer.log"; exit 1; }

echo "== 1. lock 25 tPOT on Portaldot -> wPOT on Mezo"
node user.mjs lock --network local-portaldot --amount 25 --to $BOB
wait_for "delivered.*" ; sleep 1
echo "== 2. burn 10 wPOT on Mezo -> 10 tPOT released on Portaldot"
node user.mjs burn --network local-mezo --amount 10 --to $BOB
for _ in $(seq 1 30); do [ "$(grep -c delivered "$LOG/relayer.log")" -ge 2 ] && break; sleep 1; done
echo "== 3. reverse route: lock 0.005 BTC on Mezo -> wBTC.m on Portaldot"
node user.mjs lock --network local-mezo --amount 0.005 --to $BOB
for _ in $(seq 1 30); do [ "$(grep -c delivered "$LOG/relayer.log")" -ge 3 ] && break; sleep 1; done
echo "== relayer log"; cat "$LOG/relayer.log"
echo "== solvency"
node status.mjs --profile local
