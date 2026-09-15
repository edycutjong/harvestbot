.PHONY: help build test fmt lint coverage slither stylus-check stylus-test ci
help:
	@echo "build         forge build + stylus wasm build"
	@echo "test          forge test + cargo test"
	@echo "fmt           forge fmt + cargo fmt"
	@echo "lint          forge fmt --check + cargo clippy -D warnings"
	@echo "coverage      forge coverage summary (excludes script/ test/)"
	@echo "slither       static analysis on contracts/"
	@echo "stylus-check  cargo stylus check against Robinhood Chain testnet"
	@echo "ci            lint + test + coverage + slither"

build:
	cd contracts && forge build --sizes
	cd stylus-spike && cargo build --release --target wasm32-unknown-unknown
test:
	cd contracts && forge test
	cd stylus-spike && cargo test
fmt:
	cd contracts && forge fmt
	cd stylus-spike && cargo fmt
lint:
	cd contracts && forge fmt --check
	cd stylus-spike && cargo fmt --check && cargo clippy --all-targets -- -D warnings
coverage:
	cd contracts && forge coverage --report summary --no-match-coverage "(script|test)"
slither:
	cd contracts && slither . --filter-paths "lib/" --exclude-dependencies
stylus-check:
	cd stylus-spike && cargo stylus check --endpoint https://rpc.testnet.chain.robinhood.com
ci: lint test coverage slither
