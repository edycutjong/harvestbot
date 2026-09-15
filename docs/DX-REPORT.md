# DX Report — building HarvestBot on Robinhood Chain + Stylus

A running log of what worked, what bit, and how long it took. Kept honest: every entry is
something that actually happened in this repo, dated.

## 2026-09-15 — Day 0: the spike (is Stylus live on Robinhood Chain testnet?)

**Question the whole plan hung on:** Robinhood Chain is an Arbitrum (Orbit-class) chain — WASM
support depends on its ArbOS configuration, and the public docs (`docs.robinhood.com/chain`)
never mention Stylus. If it was off, the Stylus HIFO ledger would have to live on Arbitrum
Sepolia only and the app on Robinhood Chain would be Solidity.

**Answer: live.** Three read-only probes, no funds needed:

| Probe | Robinhood Chain testnet (46630) | Arbitrum Sepolia (421614) |
|---|---|---|
| `ArbSys(0x64).arbOSVersion()` | 116 | — |
| `ArbWasm(0x71).stylusVersion()` | **3** | 3 |
| `cargo stylus check --endpoint rpc.testnet.chain.robinhood.com` | **OK** — 6.0 KB WASM, activation dry-run accepted, wasm data fee 0.000071 ETH | not run yet |

Time from "unknown" to "answered": ~15 minutes, of which ~60 s was the first WASM compile.

**Friction:**
- The Robinhood Chain docs list RPC/chain-id/explorer but **no faucet and no word on Stylus**.
  Found the faucet via web search (`faucet.testnet.chain.robinhood.com`, plus Alchemy/QuickNode
  mirrors). The precompile probe is the fastest way to answer the Stylus question on any Orbit
  chain — `cast call 0x…71 'stylusVersion()(uint16)'` — worth a line in their docs.
- `cargo stylus new --minimal` is not a flag in cargo-stylus 0.10.7 (the docs corpus suggested
  it); plain `cargo stylus new <path>` gives the Counter template.
- `forge init --no-commit` is not a flag in forge 1.5.1; `forge init --no-git` + manual
  `foundry.toml` was the path since `build/` is already the git root and the Foundry project
  lives in `contracts/`.

**Next:** fund `0x72cd3cB98A5d9B830b386EeBA7B2340132Ba557b` on both chains → `Hello` deploy
(real tx) → `cargo stylus deploy` the counter → both hashes into README "Verification".
