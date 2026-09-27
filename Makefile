.PHONY: help build test fmt lint lint-scripts coverage snapshot slither security-scan lighthouse stylus-check ci seed beats bench readiness
CRATES := stylus/ledger stylus/spike
help:
	@echo "build         forge build + stylus wasm build"
	@echo "test          forge test + cargo test"
	@echo "fmt           forge fmt + cargo fmt"
	@echo "lint          forge fmt --check + cargo fmt/clippy -D warnings (both crates) + scripts"
	@echo "lint-scripts  ruff check/format --check + shellcheck on scripts/"
	@echo "snapshot      forge gas snapshot gate (fails on >2% regression)"
	@echo "security-scan gitleaks over full git history + slither"
	@echo "lighthouse    Lighthouse CI against the live site (lighthouserc.json)"
	@echo "coverage      forge coverage summary (excludes script/ test/)"
	@echo "slither       static analysis on contracts/"
	@echo "stylus-check  cargo stylus check against Robinhood Chain testnet"
	@echo "ci            lint + test + coverage + snapshot + security-scan + readiness"
	@echo "seed          scripts/seed.sh   (needs RPC, PRIVATE_KEY, AGENT_PK, SEED_TOTAL_QTY, SWAP_LIQ_QTY, BOND_AMOUNT)"
	@echo "beats         scripts/beats.sh  (needs RPC, AGENT_PK, CHALLENGER_PK)"
	@echo "bench         scripts/bench.py  (needs RPC, PRIVATE_KEY)"
	@echo "readiness     scripts/check_submission_readiness.py"

build:
	cd contracts && forge build --sizes
	cd stylus/ledger && cargo build --release --target wasm32-unknown-unknown
test:
	cd contracts && forge test
	for c in $(CRATES); do (cd $$c && cargo test) || exit 1; done
fmt:
	cd contracts && forge fmt
	for c in $(CRATES); do (cd $$c && cargo fmt) || exit 1; done
lint:
	cd contracts && forge fmt --check
	for c in $(CRATES); do (cd $$c && cargo fmt --check && cargo clippy --all-targets -- -D warnings) || exit 1; done
	$(MAKE) lint-scripts
lint-scripts:
	ruff check scripts && ruff format --check scripts
	shellcheck scripts/*.sh
coverage:
	cd contracts && forge coverage --report summary --no-match-coverage "(script|test)"
snapshot:
	cd contracts && forge snapshot --no-match-test testFuzz --check --tolerance 2
slither:
	cd contracts && slither . --filter-paths "lib/" --exclude-dependencies --fail-medium
security-scan:
	gitleaks git . --log-opts=main
	$(MAKE) slither
lighthouse:
	npx --yes @lhci/cli@0.15 autorun --config=lighthouserc.json
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
ci: lint test coverage snapshot security-scan readiness
