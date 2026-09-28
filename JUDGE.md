# JUDGE.md — 30 seconds, no setup

**HarvestBot lets an autonomous agent harvest tax losses on Robinhood tokenized equities, bounded by an
onchain mandate it physically cannot exceed, and gets it slashed when it lies.**

Zero clicks into code: [harvestbot.edycu.dev/verify](https://harvestbot.edycu.dev/verify/) — your browser reads the receipts below from chain 46630 live, no wallet.

## Click these, in order

1. **The harvest happened** — [`0x689c4d34…6123`](https://explorer.testnet.chain.robinhood.com/tx/0x689c4d345c492c08ef06aed9341de941cb131835cce52886d700207925f26123): agent-signed, router-gated, HIFO recomputed by the Stylus ledger, 9 lots, real AMZN → real NFLX.
2. **The chain refused the rebuy** — [`0xd486468e…cf10`](https://explorer.testnet.chain.robinhood.com/tx/0xd486468ea84c6d419b28401386ce832483f809f96a35ea94e9c4a92037fecf10): status 0, `WashSaleViolation`. Same agent, same key, 40 seconds later.
3. **The rogue trade got the agent slashed** — [`0x6b896b6e…7dcb`](https://explorer.testnet.chain.robinhood.com/tx/0x6b896b6e5aa1895b8084c1000997fcb4daa219de24f2d0219e8debfdc51e7dcb): `Slashed(agent, mandate, 200000000, 20000000, 180000000, …)`, called by a third-party key. The same bond refuses stale proof: the expired beat-2 envelope ([`0x673f8459…ed51`](https://explorer.testnet.chain.robinhood.com/tx/0x673f8459a6a8205e318676cda4e25ec3c728c4d22ee44ca3d682ce8e9d5eed51)) and the executed beat-1 envelope ([`0xbbf04002…c049`](https://explorer.testnet.chain.robinhood.com/tx/0xbbf040023fa28d8f446756452d3738426ca1e56dfa49b3f92f641c58c3bbc049)) both revert `EnvelopeNotLive`.
4. **The Stylus ledger is real WASM on Robinhood Chain** — [`0xEff7…5a21`](https://explorer.testnet.chain.robinhood.com/address/0xEff7B46049fC677F58264e0ebb19dF1a39195a21) (`ArbWasm.stylusVersion() = 3` on chain 46630; deployed and activated in one `cargo stylus deploy` tx, [`0x5cc682a7…77ed`](https://explorer.testnet.chain.robinhood.com/tx/0x5cc682a744a69537987990b58c7884313c315fa7cf22998986b4fbe0dac177ed)).
5. **The numbers** — [`bench/RESULTS.md`](bench/RESULTS.md): Stylus vs Solidity `computeHarvest` on the same chain, same inputs, identical outputs, WASM program uncached (worst case). **Fair engine-to-engine figure: 1.69× less L2 gas at 64 lots, 1.79× at 128**, against a memory-optimized Solidity ledger. Against the straightforward Solidity twin we shipped: 2.87× / 3.1× — the number we first published (see the correction below).

## Receipt block

| | |
|---|---|
| Tests | 91 Foundry (100 % line · 100 % function · 98.3 % statement · 89.2 % branch on `src/` product contracts, 5 fuzz properties) + 6 Stylus native |
| Static analysis | Slither: 0 high, 0 medium — `docs/SLITHER.md` triages all 10 remaining (Low / Info / Optimization) |
| Deployed | 6 system contracts (1 Stylus + 5 Solidity) + 3 labeled MOCKs + 3 bench ledgers on Robinhood Chain testnet — `deployments/` |
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
- **`AgentBond` was redeployed on 2026-09-27** with an audit hardening (live-envelope-only challenges, no
  bond exit while the agent key is active; 8 regression tests) and beat 3 was re-run against it. The
  pre-fix V1 (`0x822f…0736`) is retired and holds only the first run's slash — details and the rest of the
  known limits in `docs/ARCHITECTURE.md`.
- **The agent is `rule-v1`** (deterministic HIFO + first allowed substitute). No LLM in the loop; the
  rationale hash commits to a plain-text rationale string. We say "agent", not "AI".
- **The bench is worst-case for Stylus**: Robinhood testnet has no ArbOS cache manager yet, so every call pays the WASM init floor. The spec had guessed ~8×; the chain says 2.9×–3.1× — we report the chain. (That was against the straightforward Solidity twin; the fair figure is 1.69×–1.79× — next line.)
- **Correction (2026-09-28) — the Stylus ratio.** We first reported 2.87× as the Stylus advantage. About 41 % of that ratio was our Solidity baseline, not the engine: the shipped Solidity twin re-reads `lots[i]` from storage on every HIFO selection pass, while the Rust ledger copies the lots to memory once. A memory-copy Solidity ledger with the Rust structure (`contracts/src/bench/TaxLotLedgerMemCopy.sol`, identical output, differential-tested) measured on the same chain puts the fair engine-to-engine figure at **1.69× at 64 lots (1.79× at 128)** — and at 8 lots that Solidity ledger is *cheaper* than uncached Stylus (0.86×). The 2.87× stays true of the twin we shipped; it is not the engine gap. [`bench/RESULTS.md`](bench/RESULTS.md)

## Links

Live site: https://harvestbot.edycu.dev · Verify in your browser, no wallet: https://harvestbot.edycu.dev/verify/ · Judge page: https://harvestbot.edycu.dev/judge/ · Deck: https://harvestbot.edycu.dev/deck/ · Demo video (2:39): https://youtu.be/Q9FVTu7iuCM

Repo: this one · Live contracts: `deployments/46630.json` · Explorer: https://explorer.testnet.chain.robinhood.com
