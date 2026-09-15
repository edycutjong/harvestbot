# Architecture — as built

Seven contracts on Robinhood Chain testnet (46630). One of them is Rust compiled to WASM (Stylus);
six are Solidity 0.8.28. The owner and the agent are **different keys**; the agent's only path into the
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
and reverts on any mismatch before mutating. `contracts/src/TaxLotLedger.sol` is the byte-for-byte
semantic twin, used for the gas benchmark and as the fallback ledger on chains without Stylus.

## Slashing (INV-6)

`AgentBond.challenge(mandate, envelope)` is permissionless. It recovers the signer through the mandate's
own EIP-712 domain, checks the envelope against the substitute map and the wash-sale guard, and — if the
mandate would have rejected it — slashes `S = min(B, L_owner + 0.2·B)` (`L_owner = 0` for a reverted
attempt), pays `0.1·S` to the challenger and `0.9·S` to the owner, and resets the agent's withdrawal
cooldown. The same proof cannot be used twice.

## What is MOCK

`MockOracle` (marks), `MockSwap` (fixed-rate venue at the oracle marks, no fee), `MockUSDC` (bond
token). All three say MOCK in their name/symbol. `MockStockToken` exists only for Foundry tests and
the Sepolia bench mirror — on Robinhood Chain the assets are the faucet's Stock Tokens.

## Storage & data

- On chain: everything above. No server, no database.
- In repo: `deployments/<chainId>.json` (addresses), `receipts/<chainId>.json` (beat tx hashes +
  numbers), `receipts/envelopes/*.hex` (the signed envelopes, incl. the rogue one), `bench/results.json`.
