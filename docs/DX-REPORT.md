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

## 2026-09-15 — Day 0, evening: the whole system on chain, three beats real

Contracts written, 73 Foundry + 6 Stylus tests, deployed, seeded with real faucet Stock Tokens, three
beats executed as real transactions (`receipts/46630.json`), Stylus-vs-Solidity bench run on the same
chain. Time from "empty repo" to "slashed on chain": one working day.

**Things that bit, in order of how much time they cost:**

1. **`forge script` cannot drive a Stylus contract.** Forge executes the script locally in its own EVM
   before broadcasting; a call into a WASM program returns `OpcodeNotFound` (the Stylus code prefix is
   not EVM bytecode) and `--skip-simulation` does not help — the script body *is* the local execution.
   Every mandate call touches the ledger, so deploy-time wiring, seeding and the beats moved to plain
   `cast send` shell scripts (`scripts/seed.sh`, `scripts/beats.sh`). The deploy script keeps the
   Stylus `setMandate` call out of its body for the same reason. Worth a paragraph in the Stylus docs:
   "Foundry scripts and Stylus contracts don't mix; use `cast`, or a Rust/TS client."
2. **`forge install` returned 0 while the clone failed** (`fetch-pack: invalid index-pack output` on the
   full OpenZeppelin history). The earlier `forge init` attempt had *also* vendored OpenZeppelin into
   `build/lib/` — 1,038 files including OZ's own `CLAUDE.md` and `.claude/skills/` — and that got
   committed. Fixed with `git filter-branch` before any remote existed; `git submodule add --depth 1`
   + `git checkout v5.4.0` is the reliable path.
3. **Slither's `--json` silently refuses to overwrite an existing file**, so a second run reports the
   *previous* findings. Delete the file first. (Cost: one wrong "0 medium" claim, corrected.)
4. **Stack too deep** twice — `proposeHarvest` (fixed by splitting into `_authenticate` /
   `_realizeChecked` / `_rotate`, which also reads better) and the deploy script (fixed with a
   `[profile.deploy] via_ir = true` used only for script runs so tests/coverage stay on the legacy
   pipeline). *Correction, 2026-09-27 audit:* that profile only covered `forge script`;
   plain `forge build` / `forge coverage` (and so `make ci` and CI stage 1) still hit the error, because
   Foundry compiles `script/` too. The deploy script now writes each address straight into its output
   struct and compiles on the default pipeline — the right fix was fewer locals, not a second profile.
5. **`stylus-sdk`'s `testing` module needs the `stylus-test` feature on a dev-dependency**, and the
   lockfile generated by `cargo stylus new` pinned an `alloy-rlp` that the stale local index could not
   resolve — `cargo update` fixed it. The `#[derive(SolidityError)]` enum does not derive `Debug`, so
   `.unwrap()` in tests needs a manual `impl Debug`. `sol_storage!` guards forbid `x.set(x.get()+1)` —
   read into a local first.
6. **`vm.writeFile` needs `fs_permissions` for every directory**, including `../receipts`.
7. **The public RPC hiccups** — one `operation timed out` during a broadcast fork setup; `--slow
   --timeout 120` was enough. Alchemy is the docs' recommendation; the public endpoint did the whole
   day otherwise.

**What was pleasant:** `cargo stylus check/deploy` just worked against Robinhood Chain — constructor
args, activation, two-fragment upload for the 27.5 KB program, all first try. The ABI-identical twin
approach meant the Foundry test suite and the Stylus native tests pin the same fixture numbers, and
the mandate did not care which ledger it was talking to.
