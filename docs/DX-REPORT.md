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

## 2026-09-15 — Day 0, later: spike CLOSED (Stylus deployed + activated + called on Robinhood Chain)

| Step | Result | Gas / cost |
|---|---|---|
| Faucet (`faucet.testnet.chain.robinhood.com`) | 0.01 ETH + 5× TSLA/AMZN/PLTR/NFLX/AMD Stock Tokens | — |
| `forge script … --broadcast` `Hello.sol` | `0x9cdc…4601`, tx `0x8cde…4026` | 352,104 gas @ 0.02 gwei ≈ 0.0000076 ETH |
| `cargo stylus deploy` Counter | code `0x3763…7498`, deploy tx `0xbb7a…7e524`, activation tx `0x685c…4fc4` | wasm data fee 0.000071 ETH |
| `cast send increment()` on the Stylus contract | 0 → 1, tx `0xeead…2e02` | 76,762 gas |

Whole spike: **0.00011 ETH**. Fallback trigger (Solidity ledger on Robinhood, Stylus mirror on Sepolia)
is retired — the Stylus ledger goes on the app chain.

**Friction:**
- The official faucet is behind Cloudflare Turnstile + a Vercel challenge: a human in a browser,
  30 seconds; not scriptable (and not something to script around). Claim daily — 0.01 ETH/24 h is
  plenty at 0.02 gwei but the Stock Tokens accumulate.
- The faucet also mints **real Robinhood testnet Stock Tokens** (plain ERC-20, 18 decimals). The
  docs never mention them. This changes the plan: the ledger can hold TSLA/AMZN/… instead of MOCK
  wrappers — logged as a deviation for the human to approve.
- The public RPC timed out once while `forge script` set up its broadcast fork ("operation timed
  out"). `--slow --timeout 120` fixed it on the retry. Alchemy's endpoint is the docs' recommendation.
- `forge install` exits 0 even when `git submodule add` fails (code 128, `fetch-pack: invalid
  index-pack output` on the full OpenZeppelin history). `git submodule add --depth 1` + checkout
  tag `v5.4.0` worked.
- `cargo stylus deploy` prints a cache-bid hint (`cargo stylus cache bid <addr> 0`); skipping for
  the spike, relevant for the ledger's gas benchmark later.

**Next (day 1, Wed 09-16):** Stylus `TaxLotLedger` skeleton (`record_lot`, `compute_harvest`) on
Robinhood Chain; decide MOCK-vs-real Stock Tokens with the human.
