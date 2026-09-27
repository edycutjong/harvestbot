# Architecture — as built

Six system contracts on Robinhood Chain testnet (46630) — one is Rust compiled to WASM (Stylus), five
are Solidity 0.8.28 — plus three labeled MOCKs (oracle, swap venue, bond USDC). The owner and the agent are **different keys**; the agent's only path into the
system is one function selector behind a router.

```mermaid
flowchart LR
    subgraph offchain["off-chain · rule-v1 agent"]
        A[agent key] -->|"1. computeHarvest (view)"| L
        A -->|"2. sign EIP-712 HarvestDecision"| E[(envelope)]
    end
    E -->|"3. execute(bytes)"| R[ExecutionRouter<br/>one target · one selector · value 0 · expiry · rate-limit]
    R -->|"proposeHarvest(bytes)"| M[HarvestMandate<br/>owner-custody vault]
    M -->|"sig · nonce · deadline · owner"| M
    M -->|"isSubstitute?"| S[SubstituteMap]
    M -->|"assertBuyAllowed"| G[WashSaleGuard<br/>30-day window]
    M -->|"price(asset)"| O[MockOracle · MOCK]
    M -->|"computeHarvest → realize"| L[TaxLotLedger<br/><b>Stylus / WASM</b><br/>HIFO specific-lot]
    M -->|"swapExactIn"| X[MockSwap · MOCK]
    M -->|"openWindow"| G
    C[anyone] -->|"challenge(mandate, envelope)"| B[AgentBond<br/>S = min(B, L + 0.2B)]
    B -->|"recoverEnvelope · subMap · guard"| M
    W[owner key] -->|"deposit / withdraw / setAgentKey"| M
```

## The one flow

`proposeHarvest` re-derives every claim in the envelope and reverts on the first disagreement:

| Step | Check | Invariant | Revert |
|---|---|---|---|
| 0 | `msg.sender == router` | INV-1 | `NotRouter` |
| 1 | `ECDSA.recover(hashDecision(d)) == agentKey` | INV-5 | `BadSignature` |
| 2 | nonce unused · `block.timestamp ≤ deadline` · `d.owner == owner()` | INV-5 | `NonceUsed` / `Expired` / `WrongOwner` |
| 3 | `subMap.isSubstitute(sell, buy)` | INV-4 | `OffMapSubstitute` |
| 4 | `guard.assertBuyAllowed(owner, buy)` | INV-3 | `WashSaleViolation` |
| 5 | `ledger.computeHarvest(owner, sell, qty, oracle.price(sell))` → `keccak(ids) == d.lotSelection`, loss < 0 | INV-2 | `SelectionMismatch` / `NoLossToHarvest` |
| 6 | `ledger.realize(...)` returns the same loss | INV-2 | `LossMismatch` |
| 7 | swap at the oracle mark; new lot's basis = proceeds; `guard.openWindow(owner, sell, now)` | INV-3 | — |

The mark price is read from the oracle **inside** the mandate — the agent never supplies the number
it is judged against.

## Custody (INV-1)

`deposit`, `withdraw`, `setAgentKey` are `onlyOwner`. `proposeHarvest` is router-only, and the router's
policy for the agent key pins `(mandate, proposeHarvest.selector, value = 0)`. A rotation changes the
ticker of what the vault holds; it never moves value out. Tested: `test_INV1_*` in `Mandate.t.sol`.

## The ledger (Stylus)

`stylus/ledger/src/lib.rs`. Storage: `lots[owner][asset]` (append-only `Lot[]`), cached open count and
open quantity. `compute_harvest` copies all lots into memory once, then runs the O(n·k) HIFO selection
(cross-multiplied basis-per-unit comparison, no division) and prorates the last lot. `realize` recomputes
and reverts on any mismatch before mutating. `contracts/src/TaxLotLedger.sol` is the semantic
twin (same ABI, same integer rounding, same tie-break: lowest lot id wins), used for the gas benchmark and as the fallback ledger on chains without Stylus.

## Slashing (INV-6)

`AgentBond.challenge(mandate, envelope)` is permissionless. It recovers the signer through the mandate's
own EIP-712 domain and accepts only a **live** envelope — addressed to the mandate's owner, nonce unused,
deadline not passed — so an executed or expired envelope can never be re-read against today's map and
windows to slash an honest agent. It then checks the substitute map and the wash-sale guard (only the
guard's own `WashSaleViolation` counts) and — if the mandate would reject it — slashes
`S = min(B, L_owner + 0.2·B)` (`L_owner = 0` for a reverted attempt), pays `0.1·S` to the challenger and
`0.9·S` to the owner, and resets the agent's withdrawal cooldown. The same proof cannot be used twice.
An agent can withdraw only after the cooldown **and** after the owner has rotated its key out of the
mandate; a staked bond backs one mandate at a time.

## What is MOCK

`MockOracle` (marks), `MockSwap` (fixed-rate venue at the oracle marks, no fee), `MockUSDC` (bond
token). All three say MOCK in their name/symbol. `MockStockToken` exists only for Foundry tests — on
Robinhood Chain the assets are the faucet's Stock Tokens (the bench ledgers use synthetic asset keys and
never touch a token).

## Storage & data

- On chain: everything above. No server, no database.
- In repo: `deployments/<chainId>.json` (addresses), `receipts/<chainId>.json` (beat tx hashes +
  numbers), `receipts/envelopes/*.hex` (the signed envelopes, incl. the rogue one), `bench/results.json`.

## Deployed build vs. source

Everything on chain 46630 was deployed from commit `4fca49e`. A 2026-09-27 audit hardened
`AgentBond` in source (commit `478019e`, 7 regression tests in `Bond.t.sol`): live-envelope-only
challenges, `WashSaleViolation`-only offence (b), and no bond exit while the agent key is active. The
**deployed** `AgentBond` (`0x822f…0736`) is the pre-hardening build; every other deployed contract is
unchanged in source. The three beats are unaffected — the beat-3 envelope was live (unused nonce,
deadline ahead) when it was challenged, so the hardened contract accepts the same proof.

## Known limitations (by design or deferred)

- **Wash-sale look-back is not enforced.** The guard walls re-buys for 30 days *after* a harvest. The IRS
  rule also disallows a loss when a substantially identical security was bought in the 30 days *before*
  the sale; the mandate does not yet check the sold asset's recent acquisitions (the ledger records
  `acquiredAt` per lot, so the check is a v2 read, not a new data model). Window arithmetic is in
  seconds (`2,592,000`), not calendar days.
- **Owner-side levers are not timelocked.** The owner curates `SubstituteMap` and sets the MOCK oracle
  marks. An owner could un-sanction a pair right before a live envelope lands and then challenge it.
  A production deploy puts map and oracle changes behind a timelock (or a real price feed).
- **The mandate does not read the bond.** Bonding is an economic layer beside the mandate: the bond is
  sized `max(1,000 USDC, 5 % AUM)` at stake time and is not re-checked as AUM grows, and
  `proposeHarvest` does not require a live bond.
- **No minimum-out on the rotation.** The MOCK venue fills at the oracle mark; a real venue needs a
  `minOut` bound in the envelope.
- **`maxSellQty` is the exact quantity sold**, not an upper bound (the name is kept for ABI stability).
- **Extreme-value arithmetic.** Solidity reverts on overflow; the Stylus engine uses `U256` and saturates
  the `U256 → I256` cast. The two agree for every realistic lot size and price (engine equivalence is
  checked at 8–128 lots in `bench/results.json`), not at values near 2²⁵⁶.
