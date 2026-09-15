.PHONY: help build test fmt lint coverage slither stylus-check ci seed beats bench readiness
help:
	@echo "build         forge build + stylus wasm build"
	@echo "test          forge test + cargo test"
	@echo "fmt           forge fmt + cargo fmt"
	@echo "lint          forge fmt --check + cargo clippy -D warnings"
	@echo "coverage      forge coverage summary (excludes script/ test/)"
	@echo "slither       static analysis on contracts/"
	@echo "stylus-check  cargo stylus check against Robinhood Chain testnet"
	@echo "ci            lint + test + coverage + slither + readiness"
	@echo "seed          scripts/seed.sh   (needs RPC, PRIVATE_KEY, AGENT_PK, SEED_TOTAL_QTY, SWAP_LIQ_QTY, BOND_AMOUNT)"
	@echo "beats         scripts/beats.sh  (needs RPC, AGENT_PK, CHALLENGER_PK)"
	@echo "bench         scripts/bench.py  (needs RPC, PRIVATE_KEY)"
	@echo "readiness     scripts/check_submission_readiness.py"

build:
	cd contracts && forge build --sizes
	cd stylus/ledger && cargo build --release --target wasm32-unknown-unknown
test:
	cd contracts && forge test
	cd stylus/ledger && cargo test
fmt:
	cd contracts && forge fmt
	cd stylus/ledger && cargo fmt
lint:
	cd contracts && forge fmt --check
	cd stylus/ledger && cargo fmt --check && cargo clippy --all-targets -- -D warnings
coverage:
	cd contracts && forge coverage --report summary --no-match-coverage "(script|test)"
slither:
	cd contracts && slither . --filter-paths "lib/" --exclude-dependencies
stylus-check:
	cd stylus/ledger && cargo stylus check --endpoint https://rpc.testnet.chain.robinhood.com
seed:
	./scripts/seed.sh
beats:
	./scripts/beats.sh
bench:
	python3 scripts/bench.py
readiness:
	python3 scripts/check_submission_readiness.py
ci: lint test coverage slither readiness
