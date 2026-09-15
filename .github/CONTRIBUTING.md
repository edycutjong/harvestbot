# Contributing

Thanks for your interest in improving HarvestBot! 🎉

## Getting Started
1. Fork the repo and branch from `main`: `git checkout -b feat/your-feature`
2. Clone with submodules: `git clone --recurse-submodules <your-fork>`
3. Toolchain: [Foundry](https://getfoundry.sh) (stable), Rust 1.91 + `wasm32-unknown-unknown`, `cargo install cargo-stylus --version 0.10.7`
4. Copy the env template: `cp .env.example .env` (testnet-only keys; never commit it)

## Before You Open a PR
- `cd contracts && forge fmt --check && forge test` passes.
- `cd stylus-spike && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test` passes.
- Add or update tests for any behavior change. Name regression tests after the defect they pin.
- Keep commits conventional (`feat:`, `fix:`, `docs:`, `chore:`, `test:`) — releases are cut from them.

## Reporting Bugs / Requesting Features
Open an issue using the provided templates. Include repro steps, expected vs.
actual behavior, chain (Robinhood Chain testnet / Arbitrum Sepolia) and tx hashes where relevant.
