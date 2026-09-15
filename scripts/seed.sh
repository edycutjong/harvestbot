#!/usr/bin/env bash
# Seed the deployed HarvestMandate with the demo portfolio shape (specs/seed-data.md §2.1b) at the
# scale the wallet actually holds: 64 lots, basis ramp $380.00 → $455.00 per share (USDC 6dp).
# Then fund the MOCK swap with the buy-side token and have the agent stake its bond.
#
# Why cast and not `forge script`: the ledger on Robinhood Chain is a Stylus (WASM) contract and
# forge's local EVM cannot execute it (OpcodeNotFound) — every mandate call touches the ledger.
#
# env: RPC, PRIVATE_KEY (owner), AGENT_PK, SEED_TOTAL_QTY, SWAP_LIQ_QTY, BOND_AMOUNT, DEPLOYMENTS (json)
set -euo pipefail
: "${RPC:?}" "${PRIVATE_KEY:?}" "${AGENT_PK:?}" "${SEED_TOTAL_QTY:?}" "${SWAP_LIQ_QTY:?}" "${BOND_AMOUNT:?}"
D=${DEPLOYMENTS:-deployments/46630.json}
j() { python3 -c "import json;print(json.load(open('$D'))['$1'])"; }
MANDATE=$(j mandate); BOND=$(j bond); USDC=$(j usdc); SWAP=$(j swap); SELL=$(j assetSell); BUY=$(j assetBuy)
AGENT=$(cast wallet address --private-key "$AGENT_PK")
LOTS=64
LOT_QTY=$(python3 -c "print($SEED_TOTAL_QTY // $LOTS)")

send() { cast send "$@" --rpc-url "$RPC" --json 2>/dev/null | python3 -c "import json,sys;r=json.loads(sys.stdin.readline());print(r['transactionHash'], 'ok' if r['status']=='0x1' else 'FAIL')"; }

echo "approve $SELL -> mandate"
send "$SELL" 'approve(address,uint256)' "$MANDATE" "$SEED_TOTAL_QTY" --private-key "$PRIVATE_KEY"
for i in $(seq 0 $((LOTS-1))); do
  BASIS=$(python3 -c "USD=10**6;ps=380*USD+(455*USD-380*USD)*$i//63;print(ps*$LOT_QTY//10**18)")
  printf "lot %2d  qty=%s  basis=%s  " "$i" "$LOT_QTY" "$BASIS"
  send "$MANDATE" 'deposit(address,uint256,uint256)' "$SELL" "$LOT_QTY" "$BASIS" --private-key "$PRIVATE_KEY"
done
echo "swap liquidity: $SWAP_LIQ_QTY of $BUY -> $SWAP"
send "$BUY" 'transfer(address,uint256)' "$SWAP" "$SWAP_LIQ_QTY" --private-key "$PRIVATE_KEY"
echo "mint $BOND_AMOUNT mUSDC -> agent $AGENT"
send "$USDC" 'mint(address,uint256)' "$AGENT" "$BOND_AMOUNT" --private-key "$PRIVATE_KEY"
echo "agent approves + stakes"
send "$USDC" 'approve(address,uint256)' "$BOND" "$BOND_AMOUNT" --private-key "$AGENT_PK"
send "$BOND" 'stake(address,uint256)' "$MANDATE" "$BOND_AMOUNT" --private-key "$AGENT_PK"
echo "done: $(cast call "$MANDATE" 'aumUsd()(uint256)' --rpc-url "$RPC") USDC(6dp) under management; bond $(cast call "$BOND" 'bondOf(address)(uint256)' "$AGENT" --rpc-url "$RPC")"
