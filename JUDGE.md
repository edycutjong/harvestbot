# JUDGE.md — 30 seconds, no setup

**HarvestBot lets an autonomous agent harvest tax losses on Robinhood tokenized equities, bounded by an
onchain mandate it physically cannot exceed, and gets it slashed when it lies.**

## Click these, in order

1. **The harvest happened** — [`0x689c4d34…6123`](https://explorer.testnet.chain.robinhood.com/tx/0x689c4d345c492c08ef06aed9341de941cb131835cce52886d700207925f26123): agent-signed, router-gated, HIFO recomputed by the Stylus ledger, 9 lots, real AMZN → real NFLX.
2. **The chain refused the rebuy** — [`0xd486468e…cf10`](https://explorer.testnet.chain.robinhood.com/tx/0xd486468ea84c6d419b28401386ce832483f809f96a35ea94e9c4a92037fecf10): status 0, `WashSaleViolation`. Same agent, same key, 40 seconds later.
3. **The rogue trade got the agent slashed** — [`0xcceb12a7…6493`](https://explorer.testnet.chain.robinhood.com/tx/0xcceb12a766ef6c8f4e861f9c7ac6f30cb495044f5032cec3fec4127c87066493): `Slashed(agent, mandate, 200000000, 20000000, 180000000, …)`.
4. **The Stylus ledger is real WASM on Robinhood Chain** — [`0xEff7…5a21`](https://explorer.testnet.chain.robinhood.com/address/0xEff7B46049fC677F58264e0ebb19dF1a39195a21) (`ArbWasm.stylusVersion() = 3` on chain 46630; deploy + activation txs in the README).
5. **The numbers** — [`bench/RESULTS.md`](bench/RESULTS.md): Stylus vs Solidity `computeHarvest` on the same chain, same inputs, identical outputs — **2.87× less L2 gas at 64 lots, 3.1× at 128**, with the WASM program uncached (worst case).

## Receipt block

| | |
|---|---|
| Tests | 80 Foundry (100 % line · 100 % function · 98.3 % statement · 89.2 % branch on `src/`, 3 fuzz properties) + 6 Stylus native |
| Static analysis | Slither: 0 high, 0 medium — `docs/SLITHER.md` triages all 10 remaining (Low / Info / Optimization) |
| Deployed | 6 system contracts (1 Stylus + 5 Solidity) + 3 labeled MOCKs + 2 bench ledgers on Robinhood Chain testnet — `deployments/` |
| Real-run cost | whole demo incl. deploy < 0.002 ETH |
| Pinned scenario | 64 lots × 10 sh, $380→$455, mark $412.30 → **exactly −$3,140.000000** on both engines |

## Reproduce the judged path (real, no flags)

`DEMO.md` → "Reproduce". The read-only `cast call` needs no wallet. `forge test` / `cargo test` need no network.

## Honest limitations

- **Testnet only.** Robinhood Chain mainnet exists; we did not deploy there (gas budget + unaudited code).
- **The oracle mark, the swap venue and the bond's USDC are MOCK contracts**, labeled in name and symbol.
  There is no AMM for Stock Tokens on the testnet. The assets themselves are real faucet tokens.
- **The "substantially identical" map is owner-curated**, not an oracle judgment — a wrong map is an owner risk.
  Map and oracle changes are not timelocked yet.
- **Wash-sale scope:** re-buys are walled for the 30 days *after* a harvest; the 30-day look-back before
  the sale is not enforced yet.
- **The deployed `AgentBond` predates a 2026-09-27 hardening** that lives in source (live-envelope-only
  challenges, no bond exit while the agent key is active; 7 regression tests). The beats are unaffected —
  details and the rest of the known limits in `docs/ARCHITECTURE.md`.
- **The agent is `rule-v1`** (deterministic HIFO + first allowed substitute). No LLM in the loop; the
  rationale hash commits to a plain-text rationale string. We say "agent", not "AI".
- **The bench is worst-case for Stylus**: Robinhood testnet has no ArbOS cache manager yet, so every call pays the WASM init floor. The spec had guessed ~8×; the chain says 2.9×–3.1× — we report the chain.

## Links

Repo: this one · Live contracts: `deployments/46630.json` · Explorer: https://explorer.testnet.chain.robinhood.com
