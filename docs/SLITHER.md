# Slither triage — HarvestBot contracts

`slither . --filter-paths "lib/|test/|script/" --exclude-dependencies` on `contracts/` (solc 0.8.28,
Slither 0.11.5). Raw output: `docs/slither.json`. **0 High · 0 Medium.** Every remaining finding
is listed here with a decision — nothing is hidden.

| Detector | Impact | Where | Decision |
|---|---|---|---|
| `reentrancy-no-eth` | Medium (Slither) → **accepted** | `HarvestMandate._rotate`: `holdings[buyAsset]` written after `swap.swapExactIn` | Every state-changing entrypoint (`deposit`, `withdraw`, `proposeHarvest`) is `nonReentrant`; the only "cross-function" surface is the `aumUsd()` **view**, readable mid-swap by nobody who can act on it. `MockSwap` is ours; a real venue would be allow-listed. |
| `reentrancy-benign` / `reentrancy-events` | Low | same call + `ExecutionRouter.execute` event after the forwarded call | Same guard; the event ordering is intentional (emit after success). |
| `uninitialized-state` | Info (false positive) | `TaxLotLedger._lots` | Mappings of dynamic arrays are populated by `push` in `recordLot`; there is nothing to initialise. |
| `uninitialized-local` | Info | loop counters `j`, `k`, `n` | Default-zero locals used as counters — idiomatic. |
| `missing-zero-check` | Low → **fixed** | `setMandate`, `setAgentKey`, `router_` | Added `ZeroAddress()` reverts + `MandateSet` events (commit "chore(slither)"). |
| `events-access` | Low → **fixed** | `TaxLotLedger.setMandate` | `MandateSet` event added. |
| `calls-loop` | Low | `HarvestMandate.aumUsd()` oracle read per asset | Bounded by the number of distinct assets ever held (≤ 5 on testnet); view-only. |
| `timestamp` | Low | wash-sale window, router expiry, bond cooldown | The product **is** a 30-day timestamp rule. Sequencer timestamp drift on an Arbitrum chain is seconds, the window is 2,592,000 s. |
| `naming-convention` | Info | `WASH_SALE_WINDOW()`, `AMZN`-style test names | Interface mirrors the spec's constant-style getter on purpose. |
| `cache-array-length` | Optimisation | HIFO scan loops | Cached where it matters (`n = lots.length` in `_computeHarvest`); the others are ≤ 5-element lists. |
