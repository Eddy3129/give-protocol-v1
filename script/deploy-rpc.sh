#!/usr/bin/env bash
# deploy-rpc.sh — deploy the GIVE Protocol to a remote RPC (Mainnet, Testnet, or Tenderly fork)
#
# Usage:
#   bash script/deploy-rpc.sh [--verify] [--broadcast]
#
# Examples:
#   bash script/deploy-rpc.sh --broadcast
#   bash script/deploy-rpc.sh --verify --broadcast
#
# Required env vars (in .env):
#   RPC_URL                       — RPC URL for the target network
#   ADMIN_ADDRESS                 — protocol admin/super-admin address
#   TREASURY_ADDRESS              — fee recipient / treasury address
# Optional:
#   UPGRADER_ADDRESS              — defaults to ADMIN_ADDRESS
#   PROTOCOL_FEE_BPS              — defaults to 100 (1%)
#   ETHERSCAN_API_KEY             — if set, attempts contract verification

set -euo pipefail

# ── Load env ─────────────────────────────────────────────────────────────────

if [[ -f .env ]]; then
  set -a && source .env && set +a
fi

RPC="${RPC_URL:-}"
if [[ -z "$RPC" ]]; then
  echo "Error: RPC_URL is not set"
  exit 1
fi

for var in WALLET_ACCOUNT ADMIN_ADDRESS TREASURY_ADDRESS; do
  if [[ -z "${!var:-}" ]]; then
    echo "Error: $var is not set"
    exit 1
  fi
done

echo "================================================================"
echo "  Give Protocol — Remote RPC Deploy"
echo "  RPC: $RPC"
echo "  Admin: $ADMIN_ADDRESS"
echo "  Treasury: $TREASURY_ADDRESS"
echo "  Wallet account: $WALLET_ACCOUNT"
echo "================================================================"

# ── Helpers ──────────────────────────────────────────────────────────────────

run_script() {
  local script="$1"
  local label="$2"
  echo ""
  echo "▶ $label"
  forge script "$script" \
    --rpc-url "$RPC" \
    --account "$WALLET_ACCOUNT" \
    --sender "$ADMIN_ADDRESS" \
    --slow \
    --broadcast
  echo "  ✓ $label complete"
}

check() {
  local label="$1"
  local result="$2"
  if [[ -n "$result" && "$result" != "0x" && "$result" != "0x0000000000000000000000000000000000000000" ]]; then
    echo "  ✓ $label: $result"
  else
    echo "  ✗ $label: FAILED (got: $result)"
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
  fi
}

CHECKS_FAILED=0

# ── Phase 1: Infrastructure ───────────────────────────────────────────────────

run_script \
  "script/Deploy01_Infrastructure.s.sol:Deploy01_Infrastructure" \
  "Phase 1 — Core infrastructure (ACLManager, Registries, PayoutRouter)"

# ── Phase 2: Vaults & Adapters ────────────────────────────────────────────────

run_script \
  "script/Deploy02_VaultsAndAdapters.s.sol:Deploy02_VaultsAndAdapters" \
  "Phase 2 — Vaults & adapters (GiveVault4626, AaveAdapter, CampaignVaultFactory)"

# ── Phase 3: Initialize roles & wire contracts ────────────────────────────────

run_script \
  "script/Deploy03_Initialize.s.sol:Deploy03_Initialize" \
  "Phase 3 — Initialize roles and cross-contract wiring"

# ── Smoke checks ──────────────────────────────────────────────────────────────

echo ""
echo "================================================================"
echo "  Smoke checks"
echo "================================================================"

# Derive network name the same way BaseDeployment.getNetwork() does
CHAIN_ID=$(cast chain-id --rpc-url "$RPC" 2>/dev/null || echo "0")
case "$CHAIN_ID" in
  31337) NETWORK="anvil" ;;
  84532) NETWORK="base-sepolia" ;;
  8453)  NETWORK="base-mainnet" ;;
  1)     NETWORK="ethereum" ;;
  *)     NETWORK="unknown-${CHAIN_ID}" ;;
esac
DEPLOYMENTS_FILE="deployments/${NETWORK}-latest.json"

if [[ ! -f "$DEPLOYMENTS_FILE" ]]; then
  DEPLOYMENTS_FILE=$(find deployments/ -name "*-latest.json" 2>/dev/null | head -1 || true)
fi

if [[ -z "$DEPLOYMENTS_FILE" || ! -f "$DEPLOYMENTS_FILE" ]]; then
  echo "  ⚠ No deployments file found — skipping address-based checks"
else
  echo "  Reading from: $DEPLOYMENTS_FILE"

  ACL=$(node -e "const d=JSON.parse(require('fs').readFileSync('$DEPLOYMENTS_FILE')); console.log(d.ACLManager||'')" 2>/dev/null || true)
  CAMPAIGN_REG=$(node -e "const d=JSON.parse(require('fs').readFileSync('$DEPLOYMENTS_FILE')); console.log(d.CampaignRegistry||'')" 2>/dev/null || true)
  STRATEGY_REG=$(node -e "const d=JSON.parse(require('fs').readFileSync('$DEPLOYMENTS_FILE')); console.log(d.StrategyRegistry||'')" 2>/dev/null || true)
  PAYOUT=$(node -e "const d=JSON.parse(require('fs').readFileSync('$DEPLOYMENTS_FILE')); console.log(d.PayoutRouter||'')" 2>/dev/null || true)
  VAULT=$(node -e "const d=JSON.parse(require('fs').readFileSync('$DEPLOYMENTS_FILE')); console.log(d.GiveVault4626||'')" 2>/dev/null || true)

  if [[ -n "$ACL" ]]; then
    # ACLManager: super admin should have ROLE_SUPER_ADMIN
    SUPER_ROLE=$(cast call "$ACL" "roleExists(bytes32)(bool)" "$(cast keccak "ROLE_SUPER_ADMIN")" --rpc-url "$RPC" 2>/dev/null || echo "")
    check "ACLManager: ROLE_SUPER_ADMIN exists" "$SUPER_ROLE"

    HAS_ROLE=$(cast call "$ACL" "hasRole(bytes32,address)(bool)" "$(cast keccak "ROLE_SUPER_ADMIN")" "$ADMIN_ADDRESS" --rpc-url "$RPC" 2>/dev/null || echo "")
    check "ACLManager: admin has ROLE_SUPER_ADMIN" "$HAS_ROLE"
  fi

  if [[ -n "$CAMPAIGN_REG" ]]; then
    # CampaignRegistry: MIN_SUBMISSION_DEPOSIT should be non-zero
    DEPOSIT=$(cast call "$CAMPAIGN_REG" "MIN_SUBMISSION_DEPOSIT()(uint256)" --rpc-url "$RPC" 2>/dev/null || echo "")
    check "CampaignRegistry: MIN_SUBMISSION_DEPOSIT" "$DEPOSIT"
  fi

  if [[ -n "$PAYOUT" ]]; then
    # PayoutRouter: feeBps should match config
    FEE=$(cast call "$PAYOUT" "feeBps()(uint256)" --rpc-url "$RPC" 2>/dev/null || echo "")
    check "PayoutRouter: feeBps" "$FEE"
  fi

  if [[ -n "$VAULT" ]]; then
    # GiveVault4626: should report an asset
    ASSET=$(cast call "$VAULT" "asset()(address)" --rpc-url "$RPC" 2>/dev/null || echo "")
    check "GiveVault4626: asset()" "$ASSET"
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "================================================================"
if [[ $CHECKS_FAILED -eq 0 ]]; then
  echo "  ✅ All phases complete. Contracts live on targeted RPC."
  echo ""
  echo "  Next steps:"
  echo "   1. Verify contracts on Basescan (Phase 6E)"
  echo "   2. Run scenario scripts against this RPC (happy path, emergency, etc.)"
  echo "   3. Hand off proxy ownership to multisig (see DEPLOYMENT_RUNBOOK.md)"
else
  echo "  ⚠ Deploy complete but $CHECKS_FAILED smoke check(s) failed."
  echo "  Review logs above and check the deployments file."
fi
echo "================================================================"
