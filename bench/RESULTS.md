# Benchmark — Stylus vs Solidity `computeHarvest` (HIFO, up to 9 picks — 4 at 8 lots)

Chain 46630 (Robinhood Chain testnet) · Solidity `0xa220D5B0b6E944266acd76288678e91a6BcfAAca` · Stylus `0x1a337c6d48bc0d19f913d16074d362d065564f86` · mark $412.30 · 50 eth_call samples per cell

| Open lots | Solidity gas (L2 compute) | Stylus gas (L2 compute) | **Solidity ÷ Stylus (L2)** | total incl. L1 calldata | Sol p50 / p95 (ms) | Stylus p50 / p95 (ms) | Identical output |
|---|---|---|---|---|---|---|---|
| 8 | 132,362 | 125,859 | **1.05×** | 146,757 / 140,254 (1.05×) | 865.0 / 925.6 | 876.5 / 916.9 | ✅ lots [7, 6, 5, 4] loss -1065142840 |
| 16 | 352,195 | 180,017 | **1.96×** | 366,590 / 194,412 (1.89×) | 864.4 / 933.2 | 875.1 / 936.4 | ✅ lots [15, 14, 13, 12, 11, 10, 9, 8, 7] loss -2020666000 |
| 32 | 720,431 | 289,013 | **2.49×** | 734,826 / 303,408 (2.42×) | 890.6 / 970.5 | 879.7 / 946.3 | ✅ lots [31, 30, 29, 28, 27, 26, 25, 24, 23] loss -2778924506 |
| 64 | 1,456,905 | 507,993 | **2.87×** | 1,471,300 / 522,388 (2.82×) | 880.2 / 928.8 | 883.2 / 951.2 | ✅ lots [63, 62, 61, 60, 59, 58, 57, 56, 55] loss -3140000000 |
| 128 | 2,929,938 | 945,989 | **3.1×** | 2,944,333 / 960,384 (3.07×) | 879.5 / 973.7 | 885.6 / 931.7 | ✅ lots [127, 126, 125, 124, 123, 122, 121, 120, 119] loss -3316273074 |

Reproduce: `RPC=... PRIVATE_KEY=... python3 scripts/bench.py` (seeds are idempotent; ~500 recordLot txs on first run; `--components-only` refreshes the gas split without re-seeding).
Gas is Arbitrum's own `NodeInterface.gasEstimateComponents` for the view call: **L2 compute** is what the two engines actually differ on; the L1 calldata share (identical calldata, ~14k) is shown in the total. Latency is `eth_call` wall-clock through the public RPC and is network-bound, not engine-bound.

**Reading the numbers honestly.** The Stylus program is *uncached* on this testnet, so every call pays a WASM initialisation floor (visible at 8 lots, where the two are near parity). Both engines pay the same cold `SLOAD` per lot; Stylus wins only on the comparison loop, so the ratio grows with portfolio size — the shape a tax-lot ledger actually has (Maya's 64 lots become hundreds over years of purchases). Caching the program (`cargo stylus cache bid`) would remove the init floor, but this testnet has no ArbOS cache manager (`ArbWasmCache.allCacheManagers()` returns `[]` on chain 46630), so these are worst-case Stylus numbers.
