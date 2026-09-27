#!/usr/bin/env bash
# The three beats, as real transactions on the deployed system.
#   beat1  HARVEST        — agent signs HIFO picks → router → mandate executes the rotation
#   beat2  BLOCKED REBUY  — agent signs a rotation back into the harvested asset → WashSaleViolation
#   beat3  SLASHED        — agent signs an off-map rotation → OffMapSubstitute; anyone challenges → bond slashed
# Reverting beats are sent with an explicit gas limit so the revert lands ON CHAIN as a receipt.
#
# env: RPC, AGENT_PK, CHALLENGER_PK, DEPLOYMENTS, RECEIPTS (json out); optional MARK_SELL (6dp)
set -euo pipefail
: "${RPC:?}" "${AGENT_PK:?}" "${CHALLENGER_PK:?}"
D=${DEPLOYMENTS:-deployments/46630.json}; OUT=${RECEIPTS:-receipts/46630.json}; mkdir -p "$(dirname "$OUT")" receipts/envelopes
j() { python3 -c "import json;print(json.load(open('$D'))['$1'])"; }
LEDGER=$(j ledger); MANDATE=$(j mandate); ROUTER=$(j router); BOND=$(j bond); GUARD=$(j guard)
OWNER=$(j owner); SELL=$(j assetSell); BUY=$(j assetBuy); OFFMAP=$(j assetOffmap)
MARK=${MARK_SELL:-412300000}
NOW=$(date +%s); DEADLINE=$((NOW + 3600))
BEAT=${1:-all}

envelope() { # $1 sell $2 buy $3 sellQty $4 lotIds $5 nonce $6 out $7 rationale
  ( cd contracts && FOUNDRY_PROFILE=deploy AGENT_PK="$AGENT_PK" SELL="$1" BUY="$2" SELL_QTY="$3" LOT_IDS="$4" NONCE="$5" DEADLINE="$DEADLINE" RATIONALE="$7" ENVELOPE_OUT="../$6" \
      forge script script/Envelope.s.sol:EnvelopeScript --rpc-url "$RPC" >/dev/null 2>&1 ) || { echo "envelope failed"; exit 1; }
  cat "$6"
}
receipt() { cast receipt "$1" --rpc-url "$RPC" --json 2>/dev/null | python3 -c "import json,sys;r=json.load(sys.stdin);print(r['status'],int(r['blockNumber'],16),int(r['gasUsed'],16))"; }
record() { python3 - "$OUT" "$@" <<'PY'
import json,sys,os
out=sys.argv[1]; k=sys.argv[2]; v=dict(zip(sys.argv[3::2], sys.argv[4::2]))
d=json.load(open(out)) if os.path.exists(out) else {}
d[k]=v; json.dump(d,open(out,'w'),indent=2)
PY
}

SELLQ=$(python3 -c "print(81728148108628507367 * $(cast call "$LEDGER" 'openQty(address,address)(uint256)' "$OWNER" "$SELL" --rpc-url "$RPC" | awk '{print $1}') // 640000000000000000000)")
NONCE=$(python3 -c "import time;print(int(time.time()))")

if [[ "$BEAT" == all || "$BEAT" == beat1 ]]; then
  echo "== BEAT 1 · HARVEST  (sellQty=$SELLQ at mark $MARK)"
  RES=$(cast call "$LEDGER" 'computeHarvest(address,address,uint256,uint256)(uint64[],int256)' "$OWNER" "$SELL" "$SELLQ" "$MARK" --rpc-url "$RPC")
  IDS=$(echo "$RES" | head -1 | tr -d '[] '); LOSS=$(echo "$RES" | tail -1 | awk '{print $1}')
  echo "   ledger says: lots [$IDS], realizedLoss=$LOSS"
  ENV=$(envelope "$SELL" "$BUY" "$SELLQ" "$IDS" "$NONCE" receipts/envelopes/beat1.hex "rule-v1:hifo:$IDS")
  TX=$(cast send "$ROUTER" 'execute(bytes)' "$ENV" --rpc-url "$RPC" --private-key "$AGENT_PK" --json 2>/dev/null | python3 -c "import json,sys;print(json.loads(sys.stdin.readline())['transactionHash'])")
  read -r ST BLK GAS <<<"$(receipt "$TX")"; echo "   tx $TX status=$ST block=$BLK gas=$GAS"
  echo "   windowEndsAt($SELL) = $(cast call "$GUARD" 'windowEndsAt(address,address)(uint256)' "$OWNER" "$SELL" --rpc-url "$RPC")"
  record beat1 tx "$TX" status "$ST" block "$BLK" gas "$GAS" lotIds "$IDS" realizedLoss "$LOSS" sellQty "$SELLQ" nonce "$NONCE"
fi

if [[ "$BEAT" == all || "$BEAT" == beat2 ]]; then
  echo "== BEAT 2 · BLOCKED REBUY  (NFLX -> AMZN inside the 30-day window)"
  BUYQ=$(cast call "$LEDGER" 'openQty(address,address)(uint256)' "$OWNER" "$BUY" --rpc-url "$RPC" | awk '{print $1}')
  RES=$(cast call "$LEDGER" 'computeHarvest(address,address,uint256,uint256)(uint64[],int256)' "$OWNER" "$BUY" "$BUYQ" 900000000 --rpc-url "$RPC")
  IDS=$(echo "$RES" | head -1 | tr -d '[] ')
  ENV=$(envelope "$BUY" "$SELL" "$BUYQ" "$IDS" "$((NONCE+1))" receipts/envelopes/beat2.hex "rule-v1:rebuy-attempt")
  echo "   dry-run: $(cast call "$ROUTER" 'execute(bytes)' "$ENV" --from "$(cast wallet address --private-key "$AGENT_PK")" --rpc-url "$RPC" 2>&1 | grep -o 'WashSaleViolation[^)]*)' | head -1 || echo reverted)"
  TX=$(cast send "$ROUTER" 'execute(bytes)' "$ENV" --rpc-url "$RPC" --private-key "$AGENT_PK" --gas-limit 1500000 --json 2>/dev/null | python3 -c "import json,sys;print(json.loads(sys.stdin.readline())['transactionHash'])" || true)
  if [[ -n "${TX:-}" ]]; then read -r ST BLK GAS <<<"$(receipt "$TX")"; echo "   tx $TX status=$ST (0x0 = reverted ON CHAIN) block=$BLK"; record beat2 tx "$TX" status "$ST" block "$BLK" gas "$GAS" expected "WashSaleViolation" nonce "$((NONCE+1))"; fi
fi

if [[ "$BEAT" == all || "$BEAT" == beat3 ]]; then
  echo "== BEAT 3 · SLASHED  (AMZN -> PLTR is off-map; the signed envelope is the proof)"
  Q=$(python3 -c "print($SELLQ // 4)")
  RES=$(cast call "$LEDGER" 'computeHarvest(address,address,uint256,uint256)(uint64[],int256)' "$OWNER" "$SELL" "$Q" "$MARK" --rpc-url "$RPC")
  IDS=$(echo "$RES" | head -1 | tr -d '[] ')
  ENV=$(envelope "$SELL" "$OFFMAP" "$Q" "$IDS" "$((NONCE+2))" receipts/envelopes/beat3-rogue.hex "rogue:offmap-attempt")
  cp receipts/envelopes/beat3-rogue.hex receipts/rogue-offmap.hex
  TX=$(cast send "$ROUTER" 'execute(bytes)' "$ENV" --rpc-url "$RPC" --private-key "$AGENT_PK" --gas-limit 1500000 --json 2>/dev/null | python3 -c "import json,sys;print(json.loads(sys.stdin.readline())['transactionHash'])" || true)
  if [[ -n "${TX:-}" ]]; then read -r ST BLK GAS <<<"$(receipt "$TX")"; echo "   attempt tx $TX status=$ST (0x0 = reverted ON CHAIN)"; record beat3_attempt tx "$TX" status "$ST" block "$BLK" expected "OffMapSubstitute"; fi
  B0=$(cast call "$BOND" 'bondOf(address)(uint256)' "$(cast wallet address --private-key "$AGENT_PK")" --rpc-url "$RPC" | awk '{print $1}')
  TX=$(cast send "$BOND" 'challenge(address,bytes)' "$MANDATE" "$ENV" --rpc-url "$RPC" --private-key "$CHALLENGER_PK" --json 2>/dev/null | python3 -c "import json,sys;print(json.loads(sys.stdin.readline())['transactionHash'])")
  read -r ST BLK GAS <<<"$(receipt "$TX")"
  B1=$(cast call "$BOND" 'bondOf(address)(uint256)' "$(cast wallet address --private-key "$AGENT_PK")" --rpc-url "$RPC" | awk '{print $1}')
  echo "   challenge tx $TX status=$ST block=$BLK  bond $B0 -> $B1 (slashed $((B0-B1)))"
  record beat3_slash tx "$TX" status "$ST" block "$BLK" gas "$GAS" bondBefore "$B0" bondAfter "$B1" slashed "$((B0-B1))"
fi
echo "receipts -> $OUT"
