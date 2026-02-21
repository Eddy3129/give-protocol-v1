# GIVE Protocol — Makefile
# Usage: make <target>
# Run `make help` to see all available targets.

.PHONY: help build clean fmt lint \
        test test-unit test-integration test-fork test-fuzz test-invariant \
        test-full test-fast test-gas test-verbose test-match \
        test-fuzz-quick test-invariant-quick \
        coverage coverage-summary coverage-full \
        deploy-local deploy-rpc deploy-verify \
        smoke-local smoke-rpc smoke-fork smoke-arbitrum smoke-optimism \
        frontend-install frontend-e2e-local frontend-e2e-rpc \
        ci check

BOLD  := \033[1m
RESET := \033[0m
CYAN  := \033[36m

FUZZ_SEED    ?= 0x1337
BASE_RPC_URL ?= https://base-rpc.publicnode.com

# ─── Help ─────────────────────────────────────────────────────────────────────

help: ## Show available targets
	@printf "$(BOLD)GIVE Protocol$(RESET)\n"
	@grep -E '^[a-zA-Z0-9_-]+:' Makefile | grep '## ' \
	  | sed 's/:[^#]*## /: ## /' \
	  | awk -F ': ## ' '{printf "  make $(CYAN)%-28s$(RESET) %s\n", $$1, $$2}'

# ─── Build ────────────────────────────────────────────────────────────────────

build: ## Compile contracts
	forge build

fmt: ## Format Solidity sources
	forge fmt

lint: ## Check formatting (no writes)
	forge fmt --check

clean: ## Remove build artifacts
	forge clean

# ─── Test — Standard ──────────────────────────────────────────────────────────

test: ## Unit + integration tests (default profile)
	forge test -v

test-unit: ## Unit tests only
	forge test --match-path "test/unit/**" -v

test-integration: ## Integration tests only
	forge test --match-path "test/integration/**" -v

test-fast: ## Fast iteration — skip fork, fuzz, invariant
	FOUNDRY_PROFILE=dev-fast forge test \
	  --no-match-path "test/fork/**:test/fuzz/**:test/invariant/**" -v

test-verbose: ## Full traces (-vvv)
	forge test -vvv

test-gas: ## Run tests with gas report
	forge test --gas-report

## Usage: make test-match MATCH=ForkTest06
test-match: ## Run tests matching MATCH= pattern
	forge test --match-path "*$(MATCH)*" -v

# ─── Test — Extended Suites ───────────────────────────────────────────────────

test-full: ## All tests including fork, fuzz, invariant
	FOUNDRY_PROFILE=full forge test -v

test-fork: ## Fork tests — requires BASE_RPC_URL
	FOUNDRY_PROFILE=fork forge test \
	  --match-path "test/fork/**" \
	  --fork-url $(BASE_RPC_URL) -v

test-fuzz: ## Fuzz tests — 10,000 runs
	FOUNDRY_PROFILE=fuzz forge test \
	  --match-path "test/fuzz/**" \
	  --fuzz-seed $(FUZZ_SEED) -v

test-fuzz-quick: ## Fuzz tests — 256 runs (fast)
	FOUNDRY_PROFILE=fuzz forge test \
	  --match-path "test/fuzz/**" \
	  --fuzz-runs 256 \
	  --fuzz-seed $(FUZZ_SEED) -v

test-invariant: ## Invariant tests — 256 runs, depth 500
	FOUNDRY_PROFILE=invariant forge test \
	  --match-path "test/invariant/**" -v

test-invariant-quick: ## Invariant tests — 64 runs, depth 200 (fast)
	FOUNDRY_PROFILE=invariant forge test \
	  --match-path "test/invariant/**" \
	  --invariant-runs 64 \
	  --invariant-depth 200 -v

# ─── Coverage ─────────────────────────────────────────────────────────────────

coverage: ## LCOV report — unit + integration
	FOUNDRY_PROFILE=coverage forge coverage \
	  --ir-minimum \
	  --report lcov \
	  --no-match-path "test/fork/**:test/fuzz/**:test/invariant/**"

coverage-summary: ## Summary table — unit + integration
	FOUNDRY_PROFILE=coverage forge coverage \
	  --ir-minimum \
	  --report summary \
	  --no-match-path "test/fork/**:test/fuzz/**:test/invariant/**"

coverage-full: ## LCOV report — all test types
	FOUNDRY_PROFILE=coverage forge coverage \
	  --ir-minimum \
	  --report lcov

# ─── Deploy ───────────────────────────────────────────────────────────────────

deploy-local: ## Deploy all contracts to local Anvil
	bash script/operations/deploy_local_all.sh

deploy-rpc: ## Deploy to live RPC — requires BASE_RPC_URL + PRIVATE_KEY
	bash script/deploy-rpc.sh

deploy-verify: ## Deploy + verify on Basescan — requires ETHERSCAN_API_KEY
	VERIFY_CONTRACTS=true forge script script/Deploy01_Infrastructure.s.sol \
	  --rpc-url $(BASE_RPC_URL) \
	  --broadcast \
	  --verify \
	  --etherscan-api-key $(ETHERSCAN_API_KEY)

# ─── Frontend — Smoke Tests ───────────────────────────────────────────────────

smoke-local: ## Viem smoke — full lifecycle on local Anvil (deploy first)
	node frontend/scripts/viem-smoke.mjs --mode=local

smoke-rpc: ## Viem smoke — RPC connectivity only (read-only)
	BASE_RPC_URL=$(BASE_RPC_URL) node frontend/scripts/viem-smoke.mjs --mode=rpc

smoke-fork: ## Viem smoke — full lifecycle on Base fork
	bash frontend/scripts/fork-smoke.sh

smoke-arbitrum: ## Viem smoke — Arbitrum RPC connectivity
	CHAIN_CONFIG=config/chains/arbitrum.json \
	  ARBITRUM_RPC_URL=$(ARBITRUM_RPC_URL) \
	  node frontend/scripts/viem-smoke.mjs --mode=rpc

smoke-optimism: ## Viem smoke — Optimism RPC connectivity
	CHAIN_CONFIG=config/chains/optimism.json \
	  OPTIMISM_RPC_URL=$(OPTIMISM_RPC_URL) \
	  node frontend/scripts/viem-smoke.mjs --mode=rpc

# ─── Frontend — E2E Tests ─────────────────────────────────────────────────────

frontend-install: ## Install frontend pnpm dependencies
	cd frontend && pnpm install

frontend-e2e-local: ## Deploy then run Vitest E2E suite on Anvil
	$(MAKE) deploy-local
	cd frontend && pnpm test:e2e

frontend-e2e-rpc: ## Vitest E2E suite against configured RPC
	cd frontend && RPC_URL=$(BASE_RPC_URL) pnpm test:e2e

# ─── Composite ────────────────────────────────────────────────────────────────

ci: fmt lint test ## Format + lint + unit+integration (CI-ready)

check: ci coverage-summary ## Full local check: CI + coverage summary
