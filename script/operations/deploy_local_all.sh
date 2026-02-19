#!/usr/bin/env bash
set -euo pipefail

RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
ADMIN_ADDRESS="${ADMIN_ADDRESS:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}"
PRIVATE_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
TREASURY_ADDRESS="${TREASURY_ADDRESS:-$ADMIN_ADDRESS}"
UPGRADER_ADDRESS="${UPGRADER_ADDRESS:-$ADMIN_ADDRESS}"
PROTOCOL_ADMIN_ADDRESS="${PROTOCOL_ADMIN_ADDRESS:-$ADMIN_ADDRESS}"
STRATEGY_ADMIN_ADDRESS="${STRATEGY_ADMIN_ADDRESS:-$ADMIN_ADDRESS}"
CAMPAIGN_ADMIN_ADDRESS="${CAMPAIGN_ADMIN_ADDRESS:-$ADMIN_ADDRESS}"
PROTOCOL_FEE_BPS="${PROTOCOL_FEE_BPS:-100}"
AUTO_REBALANCE_ENABLED="${AUTO_REBALANCE_ENABLED:-true}"
REBALANCE_INTERVAL="${REBALANCE_INTERVAL:-86400}"

if ! cast chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1; then
  echo "Anvil/RPC not reachable at $RPC_URL"
  exit 1
fi

CHAIN_ID="$(cast chain-id --rpc-url "$RPC_URL")"
echo "Detected chain ID: $CHAIN_ID"

mkdir -p deployments

# Load protocol addresses from chain config if available.
# CHAIN_CONFIG can be set externally (e.g. by fork-smoke.sh); default to base.
CHAIN_CONFIG_FILE="${CHAIN_CONFIG:-config/chains/base.json}"

_chain_field() {
  # Usage: _chain_field .protocol.usdc
  node -e "
    try {
      const d=JSON.parse(require('fs').readFileSync('$CHAIN_CONFIG_FILE','utf8'));
      const v=d$1;
      if(v!=null) process.stdout.write(String(v));
    } catch {}
  " 2>/dev/null || true
}

CONFIG_CHAIN_ID="$(_chain_field .chainId)"
CONFIG_USDC="$(_chain_field '.protocol.usdc')"
CONFIG_AAVE_POOL="$(_chain_field '.protocol.aavePool')"
CONFIG_NETWORK_NAME="$(_chain_field .networkName)"

# Verify chain config matches the actual RPC chain (when config is not local)
if [[ -n "$CONFIG_CHAIN_ID" && "$CONFIG_CHAIN_ID" != "31337" && "$CONFIG_CHAIN_ID" != "$CHAIN_ID" ]]; then
  echo "Warning: chain config chainId=$CONFIG_CHAIN_ID but RPC returned chainId=$CHAIN_ID"
fi

if [[ -z "${USDC_ADDRESS:-}" ]]; then
  if [[ -n "$CONFIG_USDC" && "$CHAIN_ID" != "31337" ]]; then
    # Fork of a known chain — use canonical address from chain config
    USDC_ADDRESS="$CONFIG_USDC"
    echo "Using canonical USDC from chain config ($CHAIN_CONFIG_FILE): $USDC_ADDRESS"
  else
    # Plain Anvil (chainId 31337) — deploy MockERC20
    echo "USDC_ADDRESS not set. Deploying local MockERC20..."
    create_output="$(forge create src/mocks/MockERC20.sol:MockERC20 \
      --rpc-url "$RPC_URL" \
      --private-key "$PRIVATE_KEY" \
      --broadcast \
      --constructor-args "USD Coin" "USDC" 6)"
    echo "$create_output"
    USDC_ADDRESS="$(echo "$create_output" | awk '/Deployed to:/ {print $3}' | tail -n1)"
    if [[ -z "$USDC_ADDRESS" ]]; then
      echo "Failed to derive deployed USDC address"
      exit 1
    fi
    echo "Using deployed local USDC: $USDC_ADDRESS"
  fi
fi

if [[ -z "${AAVE_POOL_ADDRESS:-}" && -n "$CONFIG_AAVE_POOL" && "$CHAIN_ID" != "31337" ]]; then
  AAVE_POOL_ADDRESS="$CONFIG_AAVE_POOL"
  echo "Using canonical Aave Pool from chain config: $AAVE_POOL_ADDRESS"
fi

export BROADCAST=true
export ADMIN_ADDRESS
export UPGRADER_ADDRESS
export TREASURY_ADDRESS
export PRIVATE_KEY
export PROTOCOL_FEE_BPS
export PROTOCOL_ADMIN_ADDRESS
export STRATEGY_ADMIN_ADDRESS
export CAMPAIGN_ADMIN_ADDRESS
export AUTO_REBALANCE_ENABLED
export REBALANCE_INTERVAL
export USDC_ADDRESS
export AAVE_POOL_ADDRESS="${AAVE_POOL_ADDRESS:-}"

forge script script/Deploy01_Infrastructure.s.sol:Deploy01_Infrastructure --rpc-url "$RPC_URL" --broadcast
forge script script/Deploy02_VaultsAndAdapters.s.sol:Deploy02_VaultsAndAdapters --rpc-url "$RPC_URL" --broadcast
forge script script/Deploy03_Initialize.s.sol:Deploy03_Initialize --rpc-url "$RPC_URL" --broadcast

echo "Local deployment complete."
echo "Deployment file: deployments/anvil-latest.json"
