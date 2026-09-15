# Stylus (Rust → WASM)

| Crate | Purpose |
|---|---|
| `ledger/` | **`TaxLotLedger`** — the HIFO tax-lot engine. ABI-identical to `contracts/src/TaxLotLedger.sol`; the two are benchmarked against each other on the same inputs (`scripts/bench`). |
| `spike/` | The day-0 Counter used to prove Stylus activation on Robinhood Chain testnet. Kept as the receipt. |

```bash
cd ledger
cargo test                                     # native unit tests (stylus-test VM)
cargo clippy --all-targets -- -D warnings
cargo stylus check --endpoint https://rpc.testnet.chain.robinhood.com   # WASM + activation dry-run
cargo stylus deploy --endpoint ... --private-key ... --constructor-args <owner>
```
