#!/usr/bin/env bash
# Run as soon as the Portaldot faucet pays the ticket address. Idempotent: each step skips
# itself if already done.  Usage: scripts/portaldot-go-live.sh [--wait]
#  (needs ~1,200 tPOT: deploys cost ~1,030 tPOT in revive storage deposits, measured via eth_estimateGas)
#  1. move tPOT from the native ticket account to the EVM deployer's revive-mapped account
#  2. deploy wBTC.m + PortalGateway on Portaldot V3 testnet
#  3. link routes on BOTH gateways (Portaldot <-> Mezo)
#  4. live demo: tPOT -> wPOT, wPOT -> tPOT, BTC -> wBTC.m, relayed by 2-of-3 attesters
#  5. solvency check + dashboard feed (docs/data/testnet-feed.json)
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"
WALLET=${WALLET_DIR:-/workspace/crypto-earn/wallet}
export ATTESTER_KEYS=$WALLET/portallink_attesters.json
export DEPLOYER_KEY_FILE_PORTALDOT_TESTNET=$WALLET/portaldot_test.json
export DEPLOYER_KEY_FILE_MEZO_TESTNET=$WALLET/mezo_testnet_deployer.json
export RELAYER_KEY_FILE_PORTALDOT_TESTNET=$WALLET/portaldot_test.json
export RELAYER_KEY_FILE_MEZO_TESTNET=$WALLET/mezo_testnet_deployer.json
EVM=0xA2e2aeee4C742911b07B0232610eCa01232a658E        # Portaldot EVM deployer (public)
MEZO=0xFeEde29e521cd2ebbb31AbA13c1b145090b6c4a7       # Mezo deployer (public)

forge build --quiet
cd relayer
echo "== 1. fund EVM deployer from native ticket account"
node portaldot-fund.mjs --wallet "$WALLET/portaldot_test.json" --min 1200 --reserve 1 ${1:-} || { echo "not funded yet"; exit 3; }

echo "== 2. deploy Portaldot side"
[ -f ../deploy/portaldot-testnet.json ] || node deploy.mjs --network portaldot-testnet --remote mezo-testnet

echo "== 3. link routes both ways"
node deploy.mjs --link --profile testnet

delivered() { node -e "const f=require('../docs/data/testnet-feed.json');console.log(f.transfers.filter(t=>t.status==='delivered').length)" 2>/dev/null || echo 0; }
relay_until() { for _ in $(seq 1 40); do node relayer.mjs --profile testnet --once >> ../deploy/testnet-relayer.log 2>&1 || true; [ "$(delivered)" -ge "$1" ] && return 0; sleep 10; done; echo "relay timeout"; tail -20 ../deploy/testnet-relayer.log; exit 1; }

echo "== 4. live round trip"
node user.mjs lock --network portaldot-testnet --amount 1 --to $MEZO --key-file "$WALLET/portaldot_test.json"
relay_until 1
node user.mjs burn --network mezo-testnet --amount 0.4 --to $EVM --key-file "$WALLET/mezo_testnet_deployer.json"
relay_until 2
node user.mjs lock --network mezo-testnet --amount 0.00002 --to $EVM --key-file "$WALLET/mezo_testnet_deployer.json"
relay_until 3
cat ../deploy/testnet-relayer.log

echo "== 5. solvency"
node status.mjs --profile testnet --json > ../docs/data/testnet-status.json || true
node status.mjs --profile testnet
echo "Done. Commit deploy/*.json + docs/data/*.json"
