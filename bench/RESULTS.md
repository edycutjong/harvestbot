# Benchmark — Stylus vs Solidity `computeHarvest` (HIFO, up to 9 picks — 4 at 8 lots)

Chain 46630 (Robinhood Chain testnet) · Solidity (shipped twin) `0xa220D5B0b6E944266acd76288678e91a6BcfAAca` · Solidity (memory-copy) `0x982405addD7cF595453dBBe241BB39C99aa1bb24` · Stylus `0x1a337c6d48bc0d19f913d16074d362d065564f86` · mark $412.30 · 50 eth_call samples per cell

**Two baselines, two ratios.** The *shipped twin* (`contracts/src/TaxLotLedger.sol`) re-reads `lots[i]` from storage on every HIFO selection pass; the Rust ledger copies the lots to memory once. The *memory-copy* ledger (`contracts/src/bench/TaxLotLedgerMemCopy.sol`, benchmark only, differential-tested to return identical output) gives Solidity the same structure — so **Solidity (memory-copy) ÷ Stylus is the fair engine-to-engine figure**. Solidity (shipped) ÷ Stylus is what we first published (2.87× at 64 lots); about 41% of that ratio (2.87× → 1.69×) was our Solidity baseline re-reading storage, not the engine.

| Open lots | Solidity shipped (L2) | Solidity memory-copy (L2) | Stylus (L2) | **Fair: memory-copy ÷ Stylus** | As first published: shipped ÷ Stylus | total incl. L1 (shipped / memcopy / Stylus) | p50 / p95 ms (shipped · memcopy · Stylus) | Identical output (all three) |
|---|---|---|---|---|---|---|---|---|
| 8 | 132,363 | 108,713 | 125,807 | **0.86×** | 1.05× | 146,982 / 118,740 / 135,834 | 1186.5/1220.1 · 1188.7/1209.7 · 1188.8/1224.7 | ✅ lots [7, 6, 5, 4] loss -1065142840 |
| 16 | 352,160 | 231,323 | 179,982 | **1.29×** | 1.96× | 362,187 / 241,350 / 190,009 | 1192.2/1227.2 · 1201.2/1241.7 · 1195.5/1230.1 | ✅ lots [15, 14, 13, 12, 11, 10, 9, 8, 7] loss -2020666000 |
| 32 | 720,396 | 440,005 | 288,999 | **1.52×** | 2.49× | 730,423 / 452,626 / 301,620 | 1181.9/1224.2 · 1196.7/1241.0 · 1206.1/1255.4 | ✅ lots [31, 30, 29, 28, 27, 26, 25, 24, 23] loss -2778924506 |
| 64 | 1,456,891 | 857,559 | 507,979 | **1.69×** | 2.87× | 1,469,512 / 870,180 / 520,600 | 1197.5/1246.2 · 1205.8/1246.5 · 1203.1/1236.5 | ✅ lots [63, 62, 61, 60, 59, 58, 57, 56, 55] loss -3140000000 |
| 128 | 2,929,924 | 1,693,678 | 945,964 | **1.79×** | 3.1× | 2,942,545 / 1,705,492 / 957,208 | 1213.6/1243.3 · 1215.2/1256.4 · 1193.2/1239.5 | ✅ lots [127, 126, 125, 124, 123, 122, 121, 120, 119] loss -3316273074 |

**Provenance.** The first published run (2026-09-15) measured the shipped twin vs Stylus at 64 lots as 1,456,905 vs 507,993 L2 gas (2.87×) — the numbers on the demo video, OG images and X thread. The table above is the re-run in which all three engines were measured together; L2 gas estimates drift by a few dozen gas between runs, the ratios do not.

Reproduce: `RPC=... PRIVATE_KEY=... python3 scripts/bench.py` (seeds are idempotent — a ledger that already holds N lots under the size key is not re-seeded; ~750 recordLot txs on a fresh set of ledgers; `--components-only` refreshes the gas split without re-seeding).
Gas is Arbitrum's own `NodeInterface.gasEstimateComponents` for the view call: **L2 compute** is what the engines actually differ on; the L1 calldata share (identical calldata, ~14k) is shown in the total. Latency is `eth_call` wall-clock through the public RPC and is network-bound, not engine-bound.

**Reading the numbers honestly.** The Stylus program is *uncached* on this testnet, so every call pays a WASM initialisation floor — at 8 lots the memory-copy Solidity ledger is cheaper than Stylus. All engines pay the same cold `SLOAD` per lot; Stylus wins only on the comparison loop, so the ratio grows with portfolio size — the shape a tax-lot ledger actually has (Maya's 64 lots become hundreds over years of purchases). Caching the program (`cargo stylus cache bid`) would remove the init floor, but this testnet has no ArbOS cache manager (`ArbWasmCache.allCacheManagers()` returns `[]` on chain 46630), so these are worst-case Stylus numbers.
