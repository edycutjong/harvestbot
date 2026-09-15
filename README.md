# HarvestBot

Autonomous tax-loss harvesting for tokenized equities on Robinhood Chain — bounded by an onchain
mandate the agent physically cannot exceed, backed by a slashable bond.

> Day 1 of a 16-day build (2026-09-16 → 2026-10-01). This README grows with the code; nothing
> claimed here exists unless it is linked to a transaction or a test below.

## Verification

| | |
|---|---|
| Robinhood Chain testnet (46630) | _pending first deploy_ |
| Arbitrum Sepolia (421614) | _pending first deploy_ |
| Tests | 0 |

## Layout

- `contracts/` — Solidity (Foundry): the mandate, wash-sale guard, bond, router
- `stylus-spike/` — Stylus (Rust/WASM) counter used to prove Stylus activation on Robinhood Chain testnet
- `docs/` — DX-REPORT, ARCHITECTURE, DEMO (added as they become true)

## License

MIT
