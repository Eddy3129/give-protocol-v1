# GIVE Protocol v1 - Deployment Guide

Complete guide for deploying the GIVE Protocol to Base Sepolia or Base Mainnet.

---

## Prerequisites

### 1. Install Dependencies

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Install project dependencies
forge install
```

### 2. Configure Environment

Copy `.env.example` to `.env` and configure:

```bash
cp .env.example .env
```

**Required Environment Variables:**

```bash
# Network RPC
BASE_SEPOLIA_RPC_URL=https://sepolia.base.org

# Deployer private key (needs ETH for gas)
PRIVATE_KEY=0x...

# Admin addresses
ADMIN_ADDRESS=0x...
PROTOCOL_ADMIN_ADDRESS=0x...
STRATEGY_ADMIN_ADDRESS=0x...
CAMPAIGN_ADMIN_ADDRESS=0x...
TREASURY_ADDRESS=0x...

# External contracts (Base Sepolia)
USDC_ADDRESS=0x036CbD53842c5426634e7929541eC2318f3dCF7e
AAVE_POOL_ADDRESS=0x07eA79F68B2B3df564D0A34F8e19D9B1e339814b

# Deployment settings
BROADCAST=true
VERIFY_CONTRACTS=true
BASESCAN_API_KEY=your_api_key_here
```

### 3. Fund Deployer Account

Ensure deployer has ETH for gas:

```bash
# Base Sepolia: Get testnet ETH from faucet
# https://www.coinbase.com/faucets/base-ethereum-sepolia-faucet

# Base Mainnet: Bridge ETH to Base
# https://bridge.base.org
```

---

## Deployment Process

### Phase 1: Deploy Infrastructure

Deploy core protocol contracts:

```bash
forge script script/Deploy01_Infrastructure.s.sol:Deploy01_Infrastructure \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify
```

**Deploys:**
- ACLManager (UUPS proxy) - initialized with admin + upgrader addresses
- GiveProtocolCore (UUPS proxy) - initialized with ACL manager
- StrategyRegistry (UUPS proxy) - initialized with ACL manager
- CampaignRegistry (UUPS proxy) - initialized with ACL + StrategyRegistry (deposit/durations are constants)
- NGORegistry (UUPS proxy) - initialized with ACL manager
- PayoutRouter (UUPS proxy) - initialized with 6 params (admin, acl, campaignRegistry, feeRecipient, treasury, feeBps)

**Output:** `deployments/base-sepolia-latest.json`

**Verify deployment:**

```bash
cat deployments/base-sepolia-latest.json | jq '.ACLManager, .GiveProtocolCore'
```

---

### Phase 2: Deploy Vaults & Adapters

Deploy vault infrastructure:

```bash
forge script script/Deploy02_VaultsAndAdapters.s.sol:Deploy02_VaultsAndAdapters \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify
```

**Deploys:**
- GiveVault4626 implementation
- CampaignVault4626 implementation
- CampaignVaultFactory (UUPS proxy) - initialized with acl, campaignRegistry, strategyRegistry, payoutRouter, vaultImpl
- Module manager roles (VAULT_MODULE_MANAGER_ROLE, ADAPTER_MODULE_MANAGER_ROLE, RISK_MODULE_MANAGER_ROLE)
- Main USDC Vault (UUPS proxy)
- Conservative risk profile configuration
- Aave USDC Adapter (optional, if AAVE_POOL_ADDRESS set)
- USDC StrategyManager

**Important:** Module manager roles MUST be granted BEFORE any `protocolCore.configure*` calls or they will revert with `Unauthorized`.

**Verify deployment:**

```bash
cat deployments/base-sepolia-latest.json | jq '.USDCVault, .AaveUSDCAdapter, .USDCStrategyManager'
```

---

### Phase 3: Initialize Protocol

Grant roles and register initial strategies:

```bash
forge script script/Deploy03_Initialize.s.sol:Deploy03_Initialize \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

**Performs:**
- Creates canonical protocol roles (ROLE_UPGRADER, ROLE_PROTOCOL_ADMIN, ROLE_STRATEGY_ADMIN, etc.)
  - Uses `aclManager.createRole(name, adminAddress)` - second param is ADDRESS not bytes32
  - Role hierarchy: top-level roles use `admin`, sub-roles use their parent admin
- Grants roles to admin addresses from .env
- Registers Aave USDC strategy (if adapter deployed)
- Approves and activates Aave adapter on USDC vault
- Configures auto-rebalancing settings

**Verify initialization:**

```bash
# Check roles granted
cast call $ACL_MANAGER "hasRole(bytes32,address)" \
  $(cast keccak "ROLE_STRATEGY_ADMIN") \
  $STRATEGY_ADMIN_ADDRESS \
  --rpc-url $BASE_SEPOLIA_RPC_URL

# Check strategy registered
cast call $STRATEGY_REGISTRY "listStrategyIds()" --rpc-url $BASE_SEPOLIA_RPC_URL
```

---

## Post-Deployment Operations

### Register an NGO

1. **Set NGO parameters in .env:**

```bash
NGO_ADDRESS=0x...
NGO_METADATA_CID=QmNGOMetadata...
NGO_KYC_ATTESTATION=verified-kyc-hash
NGO_ATTESTOR=0x...  # Address that verified KYC
```

2. **Run script:**

```bash
forge script script/operations/RegisterNGO.s.sol:RegisterNGO \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

---

### Register a New Strategy

1. **Deploy adapter contract first**

2. **Set strategy parameters in .env:**

```bash
STRATEGY_NAME=compound-dai
STRATEGY_ADAPTER_ADDRESS=0x...
STRATEGY_RISK_TIER=MEDIUM  # LOW, MEDIUM, or HIGH
STRATEGY_MAX_TVL=5000000000000  # $5M (18 decimals for DAI)
STRATEGY_METADATA_HASH=ipfs://QmStrategy...
```

3. **Run script:**

```bash
forge script script/operations/RegisterStrategy.s.sol:RegisterStrategy \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

---

### Add a Campaign

1. **Set campaign parameters in .env:**

```bash
CAMPAIGN_NAME=climate-action-2025
CAMPAIGN_PAYOUT_RECIPIENT=0x...  # NGO address
CAMPAIGN_STRATEGY_ID=  # Will use AaveUSDCStrategyId from deployments
CAMPAIGN_TARGET_STAKE=100000000  # $100 (6 decimals for USDC)
CAMPAIGN_MIN_STAKE=1000000  # $1 minimum
CAMPAIGN_DURATION=2592000  # 30 days in seconds
USDC_ADDRESS=0x036CbD53842c5426634e7929541eC2318f3dCF7e  # Asset for vault
VAULT_ADMIN_ADDRESS=0x...  # Vault admin (defaults to CAMPAIGN_ADMIN_ADDRESS)
LOCK_PROFILE_ID=  # Optional lock profile (defaults to bytes32(0))

# Note: Campaign submission deposit is a constant (0.005 ETH) in CampaignRegistry
```

2. **Run script:**

```bash
forge script script/operations/AddCampaign.s.sol:AddCampaign \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

**Output:** Campaign vault address saved to deployments file

---

## Upgrading Contracts

### Upgrade a Proxy Contract

Use the upgrade script to safely upgrade UUPS proxies:

```bash
# Upgrade ACLManager
forge script script/Upgrade.s.sol:Upgrade \
  --sig "upgradeACLManager()" \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast --verify

# Upgrade GiveProtocolCore
forge script script/Upgrade.s.sol:Upgrade \
  --sig "upgradeGiveProtocolCore()" \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast --verify

# Upgrade StrategyRegistry
forge script script/Upgrade.s.sol:Upgrade \
  --sig "upgradeStrategyRegistry()" \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast --verify

# Upgrade CampaignRegistry
forge script script/Upgrade.s.sol:Upgrade \
  --sig "upgradeCampaignRegistry()" \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast --verify

# Upgrade NGORegistry
forge script script/Upgrade.s.sol:Upgrade \
  --sig "upgradeNGORegistry()" \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast --verify

# Upgrade PayoutRouter
forge script script/Upgrade.s.sol:Upgrade \
  --sig "upgradePayoutRouter()" \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast --verify
```

**The upgrade script automatically:**
- Captures pre-upgrade state (uses correct getters: `feeBps()` for PayoutRouter, `canonicalRoles()` for ACLManager)
- Deploys new implementation
- Upgrades proxy via `upgradeToAndCall`
- Verifies state persistence (checks implementation updated and key state unchanged)
- Saves new implementation address to deployments JSON

**Important Getters:**
- PayoutRouter: `feeBps()` NOT `protocolFeeBps()`
- ACLManager: `canonicalRoles()` NOT `getCanonicalRoles()`
- Campaign/Strategy registries: `listCampaignIds()`, `listStrategyIds()`

---

## Testing Deployment

### Local Testing with Anvil

1. **Start Anvil:**

```bash
anvil
```

2. **Deploy to Anvil:**

```bash
# Use Anvil's default private key
export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
export ANVIL_RPC_URL=http://localhost:8545

# Run deployment phases
forge script script/Deploy01_Infrastructure.s.sol:Deploy01_Infrastructure \
  --rpc-url $ANVIL_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast

forge script script/Deploy02_VaultsAndAdapters.s.sol:Deploy02_VaultsAndAdapters \
  --rpc-url $ANVIL_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast

forge script script/Deploy03_Initialize.s.sol:Deploy03_Initialize \
  --rpc-url $ANVIL_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

3. **Check deployment:**

```bash
cat deployments/anvil-latest.json | jq
```

---

## Troubleshooting

### Deployment Fails with "Insufficient Funds"

**Solution:** Ensure deployer has enough ETH for gas

```bash
# Check balance
cast balance $ADMIN_ADDRESS --rpc-url $BASE_SEPOLIA_RPC_URL

# Get testnet ETH from faucet
```

### "Role does not exist" Error

**Solution:** Ensure Deploy03_Initialize completed successfully

```bash
# Check if roles were created
cast call $ACL_MANAGER "roleExists(bytes32)" \
  $(cast keccak "ROLE_STRATEGY_ADMIN") \
  --rpc-url $BASE_SEPOLIA_RPC_URL
```

### Contract Verification Fails

**Solution:** Manual verification

```bash
# Get contract address from deployments file
CONTRACT_ADDR=$(jq -r '.ACLManager' deployments/base-sepolia-latest.json)

# Verify manually
forge verify-contract $CONTRACT_ADDR \
  src/governance/ACLManager.sol:ACLManager \
  --chain base-sepolia \
  --etherscan-api-key $BASESCAN_API_KEY
```

### "Deployment file not found"

**Solution:** Ensure previous phase completed

```bash
# Check if deployments file exists
ls -la deployments/

# If missing, re-run previous deployment phase
```

### "Unauthorized" when calling configure methods

**Solution:** Ensure module manager roles granted in Deploy02

```bash
# Module manager roles must be granted BEFORE protocolCore.configure* calls
# Deploy02 creates: VAULT_MODULE_MANAGER_ROLE, ADAPTER_MODULE_MANAGER_ROLE, RISK_MODULE_MANAGER_ROLE
# These are granted to protocolAdmin and deployer
```

### CampaignVaultFactory deployment pattern

**Important:** CampaignVaultFactory is UUPS upgradeable, NOT a simple constructor deployment:

```solidity
// CORRECT (UUPS proxy pattern):
CampaignVaultFactory factoryImpl = new CampaignVaultFactory();
bytes memory initData = abi.encodeWithSelector(
    CampaignVaultFactory.initialize.selector,
    address(aclManager), address(campaignRegistry),
    address(strategyRegistry), address(payoutRouter),
    address(campaignVaultImpl)
);
ERC1967Proxy proxy = new ERC1967Proxy(address(factoryImpl), initData);
vaultFactory = CampaignVaultFactory(address(proxy));

// WRONG (constructor pattern):
vaultFactory = new CampaignVaultFactory(...); // Will fail - no constructor
```

---

## Security Checklist

Before mainnet deployment:

- [ ] All private keys stored securely (hardware wallet recommended)
- [ ] Admin addresses controlled by multisig
- [ ] All contracts verified on Etherscan
- [ ] Deployment addresses backed up off-chain
- [ ] Role assignments audited
- [ ] Initial parameters reviewed (fees, risk limits, etc.)
- [ ] Emergency procedures documented
- [ ] Upgrade authorization tested
- [ ] Gas costs calculated and funded
- [ ] External dependencies verified (USDC, Aave addresses)

---

## Contract Addresses

After deployment, contract addresses are available in:

```
deployments/{network}-latest.json
```

### Example for Base Sepolia:

```bash
cat deployments/base-sepolia-latest.json | jq '{
  ACLManager,
  GiveProtocolCore,
  StrategyRegistry,
  CampaignRegistry,
  NGORegistry,
  PayoutRouter,
  USDCVault,
  CampaignVaultFactory
}'
```

---

## Support

For deployment issues:
1. Check `deployments/` directory for saved addresses
2. Review transaction logs in deployment output
3. Verify on Basescan: https://sepolia.basescan.org
4. Consult technical documentation

---

## Appendix: Environment Variable Reference

| Variable | Required | Description | Example |
|----------|----------|-------------|---------|
| `BASE_SEPOLIA_RPC_URL` | Yes | RPC endpoint | `https://sepolia.base.org` |
| `PRIVATE_KEY` | Yes | Deployer private key | `0x...` |
| `ADMIN_ADDRESS` | Yes | Super admin (multisig recommended) | `0x...` |
| `PROTOCOL_ADMIN_ADDRESS` | Yes | Protocol operations admin | `0x...` |
| `STRATEGY_ADMIN_ADDRESS` | Yes | Strategy management admin | `0x...` |
| `CAMPAIGN_ADMIN_ADDRESS` | Yes | Campaign approval admin | `0x...` |
| `TREASURY_ADDRESS` | Yes | Protocol fee recipient | `0x...` |
| `USDC_ADDRESS` | Yes | USDC token address | `0x036CbD...` |
| `AAVE_POOL_ADDRESS` | No | Aave V3 pool (optional) | `0x07eA79...` |
| `BROADCAST` | No | Execute transactions | `true` or `false` |
| `VERIFY_CONTRACTS` | No | Verify on Etherscan | `true` or `false` |
| `BASESCAN_API_KEY` | No | For verification | API key |
| `CAMPAIGN_SUBMISSION_DEPOSIT` | No | Campaign deposit (wei) | `5000000000000000` |
| `MIN_STAKE_DURATION` | No | Min stake time (seconds) | `3600` |
| `CHECKPOINT_DURATION` | No | Checkpoint period (seconds) | `604800` |
| `PROTOCOL_FEE_BPS` | No | Protocol fee (basis points) | `100` |
