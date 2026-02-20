#!/usr/bin/env bash
# fork-smoke.sh — deploy contracts on top of a forked chain, then run the full
# viem integration suite against live protocol state.
#
# Usage:
#   bash frontend/scripts/fork-smoke.sh
#   CHAIN_CONFIG=config/chains/arbitrum.json bash frontend/scripts/fork-smoke.sh
#
# Env vars:
#   CHAIN_CONFIG        path to chain config JSON (default: config/chains/base.json)
#   FORK_BLOCK_NUMBER   optional — pin a specific block for reproducibility
#   ANVIL_PORT          optional — default 8546 (avoids clashing with plain anvil on 8545)
set -euo pipefail

CHAIN_CONFIG="${CHAIN_CONFIG:-config/chains/base.json}"
ANVIL_PORT="${ANVIL_PORT:-8546}"
ANVIL_URL="http://127.0.0.1:${ANVIL_PORT}"
ANVIL_PID=""

# ── Read chain config ────────────────────────────────────────────────────────

_field() {
  node -e "
    try {
      const d=JSON.parse(require('fs').readFileSync('$CHAIN_CONFIG','utf8'));
      const v=d$1;
      if(v!=null) process.stdout.write(String(v));
    } catch(e) { process.stderr.write('chain config error: '+e.message+'\n'); }
  " 2>/dev/null || true
}

CHAIN_NAME="$(_field .name)"
CHAIN_ID="$(_field .chainId)"
RPC_ENV_VAR="$(_field .rpcEnvVar)"
DEPLOYMENT_FILE="$(_field .deploymentFile)"
PROTOCOL_USDC="$(_field '.protocol.usdc')"
USDC_BALANCE_OF_SLOT="$(_field '.protocol.usdcBalanceOfSlot')"

if [[ -z "$CHAIN_NAME" ]]; then
  echo "Error: could not read chain config at $CHAIN_CONFIG"
  exit 1
fi

echo "fork-smoke: chain=$CHAIN_NAME chainId=$CHAIN_ID config=$CHAIN_CONFIG"

# ── Resolve RPC URL ──────────────────────────────────────────────────────────

FORK_RPC_URL="${!RPC_ENV_VAR:-}"
if [[ -z "$FORK_RPC_URL" ]]; then
  echo "Error: $RPC_ENV_VAR is not set (required for $CHAIN_NAME fork)"
  exit 1
fi

# ── Cleanup ──────────────────────────────────────────────────────────────────

cleanup() {
  if [[ -n "$ANVIL_PID" ]]; then
    kill "$ANVIL_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ── Start forked Anvil ───────────────────────────────────────────────────────

FORK_ARGS=(--fork-url "$FORK_RPC_URL" --port "$ANVIL_PORT" --silent)
if [[ -n "${FORK_BLOCK_NUMBER:-}" ]]; then
  FORK_ARGS+=(--fork-block-number "$FORK_BLOCK_NUMBER")
  echo "fork-smoke: forking $CHAIN_NAME at block $FORK_BLOCK_NUMBER"
else
  echo "fork-smoke: forking $CHAIN_NAME at latest block"
fi

anvil "${FORK_ARGS[@]}" &
ANVIL_PID=$!

for i in $(seq 1 20); do
  if cast chain-id --rpc-url "$ANVIL_URL" >/dev/null 2>&1; then break; fi
  sleep 0.5
done

if ! cast chain-id --rpc-url "$ANVIL_URL" >/dev/null 2>&1; then
  echo "Error: anvil did not start on port $ANVIL_PORT"
  exit 1
fi

echo "fork-smoke: anvil ready at $ANVIL_URL"

# ── Deploy protocol contracts ────────────────────────────────────────────────

CHAIN_CONFIG="$CHAIN_CONFIG" \
RPC_URL="$ANVIL_URL" \
  bash script/operations/deploy_local_all.sh

echo "fork-smoke: deployment complete"

# ── Fund test account with USDC via storage slot cheat ──────────────────────
# Anvil fork supports anvil_setStorageAt to write directly to token balances.
# The balanceOf slot comes from the chain config.

USER_ADDR="0x70997970C51812dc3A010C7d01b50e0d17dc79C8"

if [[ -n "$PROTOCOL_USDC" && -n "$USDC_BALANCE_OF_SLOT" && "$USDC_BALANCE_OF_SLOT" != "null" ]]; then
  SLOT=$(cast index address "$USER_ADDR" "$USDC_BALANCE_OF_SLOT" 2>/dev/null || true)
  if [[ -n "$SLOT" ]]; then
    # Fund with 160,000 USDC (6 decimals = 160000 * 10^6 = 0x2540BE400000 ... use 10,000 USDC = 0x2540BE4000)
    cast rpc anvil_setStorageAt \
      "$PROTOCOL_USDC" \
      "$SLOT" \
      "0x0000000000000000000000000000000000000000000000000000002540BE4000" \
      --rpc-url "$ANVIL_URL" >/dev/null 2>&1 \
      || echo "fork-smoke: USDC storage cheat failed (slot $USDC_BALANCE_OF_SLOT may be wrong for this chain)"

    ACTUAL=$(cast call "$PROTOCOL_USDC" "balanceOf(address)(uint256)" "$USER_ADDR" \
      --rpc-url "$ANVIL_URL" 2>/dev/null || echo "0")
    echo "fork-smoke: user USDC balance after cheat = $ACTUAL"
  fi
else
  echo "fork-smoke: no USDC storage slot configured — skipping balance cheat"
fi

# ── Run viem smoke in local mode ─────────────────────────────────────────────

CHAIN_CONFIG="$CHAIN_CONFIG" \
ANVIL_RPC_URL="$ANVIL_URL" \
DEPLOYMENT_FILE="$DEPLOYMENT_FILE" \
FORK_MODE="1" \
  node frontend/scripts/viem-smoke.mjs --mode=local

echo "fork-smoke: done"
