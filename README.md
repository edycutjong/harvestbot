# HarvestBot

Autonomous tax-loss harvesting for tokenized equities on Robinhood Chain — bounded by an onchain
mandate the agent physically cannot exceed, backed by a slashable bond.

> Day 1 of a 16-day build (2026-09-16 → 2026-10-01). This README grows with the code; nothing
> claimed here exists unless it is linked to a transaction or a test below.

## Verification

Every row is a live link. Nothing is listed here until it is on chain.

| Chain | Contract | Address | Tx |
|---|---|---|---|
| Robinhood Chain testnet (46630) | `Hello.sol` (Solidity) — first real tx | [`0x9cdc…4601`](https://explorer.testnet.chain.robinhood.com/address/0x9cdc9d7e668f4e4a7173646ea12677051ae94601) | [deploy `0x8cde…4026`](https://explorer.testnet.chain.robinhood.com/tx/0x8cdee7782163b22cc1fd038b762554f9bf44ca1f53dd8d920fd2ca3c93ec4026) |
| Robinhood Chain testnet (46630) | `stylus-spike` Counter (Rust → WASM, **Stylus**) | [`0x3763…7498`](https://explorer.testnet.chain.robinhood.com/address/0x37632c6cadd87f3942238aa65f7ecf92f4707498) | [deploy `0xbb7a…7e524`](https://explorer.testnet.chain.robinhood.com/tx/0xbb7ab9d84b92495276c635709e536efe8067c73b8a51a000663fb3689d37e524) · [activate `0x685c…4fc4`](https://explorer.testnet.chain.robinhood.com/tx/0x685c814ae0c0d62e56c04049c7a33e89faec31abea0778e9c018cfd2c9044fc4) · [increment `0xeead…2e02`](https://explorer.testnet.chain.robinhood.com/tx/0xeead6981a489398cd5ca6671e9f822bb3a7cf2e7473238bd158698db97932e02) |
| Arbitrum Sepolia (421614) | — | _pending_ | — |

| | |
|---|---|
| Tests | 0 (day 1 — the ledger is not written yet) |
| Stylus on Robinhood Chain | **confirmed** — `ArbWasm.stylusVersion() = 3`, counter deployed + activated + called (see rows above) |
| Deployer | `0x72cd3cB98A5d9B830b386EeBA7B2340132Ba557b` (testnet-only key) |

**Robinhood testnet Stock Tokens** (ERC-20, 18 dec, from the [official faucet](https://faucet.testnet.chain.robinhood.com)):
TSLA `0xc9f9c86933092bbbfff3ccb4b105a4a94bf3bd4e` · AMZN `0x5884ad2f920c162cfbbacc88c9c51aa75ec09e02` · PLTR `0x1fbe1a0e43594b3455993b5de5fd0a7a266298d0` · NFLX `0x3b8262a63d25f0477c4dde23f83cfe22cb768c93` · AMD `0x71178bac73cbeb415514eb542a8995b82669778d`

## Layout

- `contracts/` — Solidity (Foundry): the mandate, wash-sale guard, bond, router
- `stylus-spike/` — Stylus (Rust/WASM) counter used to prove Stylus activation on Robinhood Chain testnet
- `docs/` — DX-REPORT, ARCHITECTURE, DEMO (added as they become true)

## License

MIT
