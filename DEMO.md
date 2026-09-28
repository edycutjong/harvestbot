# DEMO — the three beats, as they happened on Robinhood Chain testnet

Everything below is a real transaction on chain **46630**. Nothing is mocked except the three things
labeled MOCK (the oracle mark, the fixed-rate swap venue, the bond's USDC) — the assets are Robinhood's
own testnet Stock Tokens, the ledger is a Stylus (WASM) contract, and the agent key is a different key
from the owner's.

## Receipt

| | |
|---|---|
| Owner (Maya) | [`0x72cd…557b`](https://explorer.testnet.chain.robinhood.com/address/0x72cd3cB98A5d9B830b386EeBA7B2340132Ba557b) |
| Agent session key | [`0xF783…457E`](https://explorer.testnet.chain.robinhood.com/address/0xF783e954a1827bD33d210Ed2d21120aC1511457E) — can call exactly one function through the router |
| Portfolio | 64 lots of **real AMZN** (faucet Stock Token), basis ramp $380.00 → $455.00/share, 5.0 AMZN total |
| MOCK oracle mark | AMZN $412.30 · NFLX $900.00 · PLTR $150.00 |
| Bond | 1,000.00 mUSDC (= `max(1000, 5% × AUM)`, AUM $2,061.50) |

| Beat | What the agent signed | What the chain did | Tx |
|---|---|---|---|
| **1 · HARVEST** | sell 638501157098660213 wei AMZN (0.638501 sh), HIFO lots `[63,62,61,60,59,58,57,56,55]`, rotate → NFLX | Recomputed HIFO on the Stylus ledger, matched the selection, realized **−$24.531251**, swapped AMZN→NFLX, opened the 30-day window | [`0x689c4d34…6123`](https://explorer.testnet.chain.robinhood.com/tx/0x689c4d345c492c08ef06aed9341de941cb131835cce52886d700207925f26123) ✅ block 119852570, 1,096,548 gas |
| **2 · BLOCKED REBUY** | rotate NFLX → AMZN, 40 seconds later | **Reverted on chain**: `WashSaleViolation(owner, AMZN, AMZN, 1792060681)` — the way back is walled until the window ends | [`0xd486468e…cf10`](https://explorer.testnet.chain.robinhood.com/tx/0xd486468ea84c6d419b28401386ce832483f809f96a35ea94e9c4a92037fecf10) ❌ status 0, block 119852786 |
| **3 · SLASHED** | rotate AMZN → PLTR (not a sanctioned substitute) | Attempt **reverted on chain** `OffMapSubstitute`; then `challenge()` was called with the agent-signed envelope as proof → bond **1,000 → 800 mUSDC** (20 % slashed: 20 bounty to the challenger, 180 restitution to the owner — the challenger is a third-party key, `0x0Fec…28e2`, neither owner nor agent; `challenge` is permissionless). Same bond, stale proof: the expired beat-2 envelope reverts `EnvelopeNotLive` | attempt [`0xd8b6e577…94c8`](https://explorer.testnet.chain.robinhood.com/tx/0xd8b6e5779f53a1cc157a9962c8546e0e5bdef3cc1e62f441458a19359c5994c8) ❌ · challenge [`0x6b896b6e…7dcb`](https://explorer.testnet.chain.robinhood.com/tx/0x6b896b6e5aa1895b8084c1000997fcb4daa219de24f2d0219e8debfdc51e7dcb) ✅ block 125092624 · stale envelope [`0x673f8459…ed51`](https://explorer.testnet.chain.robinhood.com/tx/0x673f8459a6a8205e318676cda4e25ec3c728c4d22ee44ca3d682ce8e9d5eed51) ❌ |

Total gas cost of the whole demo, deploy included: **< 0.002 ETH** at 0.02 gwei.

## Why the numbers are small

The faucet hands out 5 of each Stock Token per day, so the on-chain portfolio is the spec's 64-lot
shape at **1/128 scale** (0.078125 AMZN per lot). The same engine, same ramp, same 9 HIFO picks at
10 shares per lot realizes **exactly −$3,140.000000** — pinned in `contracts/test/fixtures/expected.json`
and asserted by `forge test` (Solidity) and `cargo test` (Stylus). Real small numbers on chain, the
big number in the deterministic test — never the other way round.

## Reproduce

```bash
git clone --recurse-submodules <repo> && cd harvestbot
cd contracts && forge test            # 91 tests, incl. the -3,140.00 scenario and 5 fuzz properties
cd ../stylus/ledger && cargo test     # 6 native tests on the WASM engine

# live (read-only, no wallet): ask the deployed Stylus ledger for the HIFO selection
cast call 0xEff7B46049fC677F58264e0ebb19dF1a39195a21 \
  'computeHarvest(address,address,uint256,uint256)(uint64[],int256)' \
  0x72cd3cB98A5d9B830b386EeBA7B2340132Ba557b 0x5884aD2f920c162CFBbACc88C9C51AA75eC09E02 638501157098660213 412300000 \
  --rpc-url https://rpc.testnet.chain.robinhood.com
# → [55, 54, 53, 52, 51, 50, 49, 48, 47]
#   -18321704   (−$18.321704, 6-dp USD; captured live 2026-09-27)
#   A smaller loss: beat 1 already sold lots 63–56 and part of 55, so the ledger
#   now answers with the next nine. Beat 1's own picks and −24531251 are in its HarvestReport event.

# re-run the beats yourself against a fresh deploy (needs a funded testnet key — see .env.example)
scripts/seed.sh && scripts/beats.sh
```

Deployed addresses: `deployments/46630.json`. Raw receipts: `receipts/46630.json`. The rogue envelope
that got the agent slashed is committed at `receipts/envelopes/beat3-rogue.hex` — decode it with
`cast abi-decode` and verify the signature recovers to the agent key with `HarvestMandate.recoverEnvelope`.

## The killer number

`python3 scripts/bench.py` — three ledgers deployed side by side on chain 46630 (`deployments/46630-bench.json`),
seeded with 8/16/32/64/128 lots, `computeHarvest` for the 9-lot HIFO harvest (4 lots at size 8) measured with Arbitrum's own
`NodeInterface.gasEstimateComponents`. **Two Solidity baselines:** the straightforward twin we shipped
(`TaxLotLedger.sol`, re-reads `lots[i]` from storage on every selection pass) and a memory-copy ledger with the Rust
structure (`contracts/src/bench/TaxLotLedgerMemCopy.sol`, benchmark only). **Memory-copy ÷ Stylus is the fair
engine-to-engine figure.** Re-run 2026-09-28, all three engines in one run:

| Open lots | Solidity shipped L2 | Solidity memory-copy L2 | Stylus L2 | **fair ratio** | vs shipped twin |
|---|---|---|---|---|---|
| 8 | 132,363 | 108,713 | 125,807 | **0.86×** | 1.05× |
| 16 | 352,160 | 231,323 | 179,982 | **1.29×** | 1.96× |
| 32 | 720,396 | 440,005 | 288,999 | **1.52×** | 2.49× |
| **64** | 1,456,891 | 857,559 | 507,979 | **1.69×** | 2.87× |
| 128 | 2,929,924 | 1,693,678 | 945,964 | **1.79×** | 3.1× |

Identical `lotIds` and `realizedLoss` across all three at every size (the 64-lot row is Maya's exact −$3,140.000000).
We first published 2.87× (1,456,905 → 507,993, 15 Sep run) as the Stylus advantage; ~41 % of that ratio was our
Solidity baseline re-reading storage. At 8 lots the memory-copy ledger beats uncached Stylus (0.86×). The program is
uncached on this testnet (no ArbOS cache manager), so these are worst-case Stylus numbers.
Full table with latency percentiles: [`bench/RESULTS.md`](bench/RESULTS.md).
