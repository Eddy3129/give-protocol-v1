// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

/**
 * @title BaseDeployment
 * @author GIVE Labs
 * @notice Base deployment script with helpers for saving/loading deployment addresses
 * @dev Provides JSON-based persistence of deployment addresses across deployment phases
 */
abstract contract BaseDeployment is Script {
    string internal constant DEPLOYMENTS_DIR = "./deployments";
    // ============================================================
    // STATE VARIABLES
    // ============================================================

    /// @notice Path to save deployment addresses
    string public deploymentsPath;

    /// @notice Current network name (anvil, base-sepolia, base-mainnet)
    string public network;

    /// @notice Timestamp of current deployment
    uint256 public deploymentTimestamp;

    // ============================================================
    // SETUP
    // ============================================================

    function setUp() public virtual {
        deploymentTimestamp = block.timestamp;
        network = getNetwork();
        deploymentsPath = getDeploymentsPath();

        _ensureDeploymentsStorage();

        console.log("========================================");
        console.log("GIVE Protocol v1 - Deployment Script");
        console.log("========================================");
        console.log("Network:", network);
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", msg.sender);
        console.log("Timestamp:", deploymentTimestamp);
        console.log("========================================");
    }

    // ============================================================
    // NETWORK DETECTION
    // ============================================================

    function getNetwork() internal view returns (string memory) {
        uint256 chainId = block.chainid;

        if (chainId == 31337) return "anvil";
        if (chainId == 84532) return "base-sepolia";
        if (chainId == 8453) return "base-mainnet";
        if (chainId == 1) return "ethereum";
        if (chainId == 42161) return "arbitrum-one";
        if (chainId == 421614) return "arbitrum-sepolia";
        if (chainId == 10) return "optimism";
        if (chainId == 11155420) return "optimism-sepolia";

        revert("Unsupported chain ID");
    }

    // ============================================================
    // DEPLOYMENT PATH MANAGEMENT
    // ============================================================

    function getDeploymentsPath() internal view returns (string memory) {
        return string.concat("./deployments/", network, "-latest.json");
    }

    function getDeploymentsArchivePath() internal view returns (string memory) {
        return string.concat("./deployments/", network, "-", vm.toString(deploymentTimestamp), ".json");
    }

    // ============================================================
    // SAVE DEPLOYMENT ADDRESS
    // ============================================================

    function saveDeployment(string memory key, address addr) internal {
        string memory objectKey = "deployment";

        // Serialize address
        vm.serializeAddress(objectKey, key, addr);
        _upsertLatestAddress(key, addr);

        console.log("Saved:", key, "->", addr);
    }

    function saveDeploymentString(string memory key, string memory value) internal {
        string memory objectKey = "deployment";
        vm.serializeString(objectKey, key, value);
        _upsertLatestString(key, value);
        console.log("Saved:", key, "->", value);
    }

    function saveDeploymentUint(string memory key, uint256 value) internal {
        string memory objectKey = "deployment";
        vm.serializeUint(objectKey, key, value);
        _upsertLatestUint(key, value);
        console.log("Saved:", key, "->", value);
    }

    function saveDeploymentBytes32(string memory key, bytes32 value) internal {
        string memory objectKey = "deployment";
        vm.serializeBytes32(objectKey, key, value);
        _upsertLatestBytes32(key, value);
        console.log("Saved:", key, "->", vm.toString(value));
    }

    // ============================================================
    // FINALIZE AND WRITE JSON
    // ============================================================

    function finalizeDeployment() internal {
        string memory objectKey = "deployment";

        // Add metadata
        string memory metadata = vm.serializeString(objectKey, "network", network);
        metadata = vm.serializeUint(objectKey, "chainId", block.chainid);
        metadata = vm.serializeUint(objectKey, "timestamp", deploymentTimestamp);
        metadata = vm.serializeAddress(objectKey, "deployer", msg.sender);

        _upsertLatestString("network", network);
        _upsertLatestUint("chainId", block.chainid);
        _upsertLatestUint("timestamp", deploymentTimestamp);
        _upsertLatestAddress("deployer", msg.sender);

        console.log("Deployment saved to:", deploymentsPath);

        // Archive with timestamp
        string memory archivePath = getDeploymentsArchivePath();
        vm.writeJson(metadata, archivePath);
        console.log("Deployment archived to:", archivePath);
    }

    function _ensureDeploymentsStorage() private {
        if (!vm.exists(DEPLOYMENTS_DIR)) {
            vm.createDir(DEPLOYMENTS_DIR, true);
        }

        if (!vm.exists(deploymentsPath)) {
            vm.writeFile(deploymentsPath, "{}");
        }
    }

    function _upsertLatestAddress(string memory key, address value) private {
        _upsertLatestJsonValue(key, string.concat('"', vm.toString(value), '"'));
    }

    function _upsertLatestBytes32(string memory key, bytes32 value) private {
        _upsertLatestJsonValue(key, string.concat('"', vm.toString(value), '"'));
    }

    function _upsertLatestString(string memory key, string memory value) private {
        _upsertLatestJsonValue(key, string.concat('"', value, '"'));
    }

    function _upsertLatestUint(string memory key, uint256 value) private {
        _upsertLatestJsonValue(key, vm.toString(value));
    }

    function _upsertLatestJsonValue(string memory key, string memory jsonValue) private {
        vm.writeJson(jsonValue, deploymentsPath, string.concat(".", key));
    }

    // ============================================================
    // LOAD DEPLOYMENT ADDRESS
    // ============================================================

    function loadDeployment(string memory key) public view returns (address) {
        string memory json = vm.readFile(deploymentsPath);
        bytes memory data = vm.parseJson(json, string.concat(".", key));
        address addr = abi.decode(data, (address));

        console.log("Loaded:", key, "->", addr);
        return addr;
    }

    function loadDeploymentOrZero(string memory key) internal view returns (address) {
        string memory json = vm.readFile(deploymentsPath);
        if (!_jsonContainsKey(json, key)) {
            console.log("Not found:", key, "(using zero address)");
            return address(0);
        }

        bytes memory data = vm.parseJson(json, string.concat(".", key));
        address addr = abi.decode(data, (address));
        console.log("Loaded:", key, "->", addr);
        return addr;
    }

    function _jsonContainsKey(string memory json, string memory key) private pure returns (bool) {
        bytes memory haystack = bytes(json);
        bytes memory needle = bytes(string.concat('"', key, '"'));

        if (needle.length == 0 || needle.length > haystack.length) {
            return false;
        }

        for (uint256 i = 0; i <= haystack.length - needle.length; i++) {
            bool matched = true;
            for (uint256 j = 0; j < needle.length; j++) {
                if (haystack[i + j] != needle[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) {
                return true;
            }
        }

        return false;
    }

    function loadDeploymentBytes32(string memory key) internal view returns (bytes32) {
        string memory json = vm.readFile(deploymentsPath);
        bytes memory data = vm.parseJson(json, string.concat(".", key));
        bytes32 value = abi.decode(data, (bytes32));

        console.log("Loaded:", key, "->", vm.toString(value));
        return value;
    }

    // ============================================================
    // HELPER FUNCTIONS
    // ============================================================

    function requireEnv(string memory key) internal view returns (string memory) {
        try vm.envString(key) returns (string memory value) {
            require(bytes(value).length > 0, string.concat("Empty env var: ", key));
            return value;
        } catch {
            revert(string.concat("Missing env var: ", key));
        }
    }

    function requireEnvAddress(string memory key) internal view returns (address) {
        address addr = vm.envAddress(key);
        require(addr != address(0), string.concat("Zero address in env var: ", key));
        return addr;
    }

    function requireEnvUint(string memory key) internal view returns (uint256) {
        return vm.envUint(key);
    }

    function getEnvAddressOr(string memory key, address defaultValue) internal view returns (address) {
        try vm.envAddress(key) returns (address value) {
            return value != address(0) ? value : defaultValue;
        } catch {
            return defaultValue;
        }
    }

    function getEnvUintOr(string memory key, uint256 defaultValue) internal view returns (uint256) {
        try vm.envUint(key) returns (uint256 value) {
            return value;
        } catch {
            return defaultValue;
        }
    }

    function getEnvBoolOr(string memory key, bool defaultValue) internal view returns (bool) {
        try vm.envBool(key) returns (bool value) {
            return value;
        } catch {
            return defaultValue;
        }
    }

    function getEnvBytes32Or(string memory key, bytes32 defaultValue) internal view returns (bytes32) {
        try vm.envBytes32(key) returns (bytes32 value) {
            return value;
        } catch {
            return defaultValue;
        }
    }

    // ============================================================
    // VERIFICATION HELPERS
    // ============================================================

    function verifyContract(address contractAddress, bytes memory constructorArgs) internal {
        bool shouldVerify = getEnvBoolOr("VERIFY_CONTRACTS", false);

        if (!shouldVerify) {
            console.log("Skipping verification (VERIFY_CONTRACTS=false)");
            return;
        }

        console.log("Verifying contract at:", contractAddress);

        try vm.ffi(buildVerifyCommand(contractAddress, constructorArgs)) returns (bytes memory result) {
            console.log("Verification result:", string(result));
        } catch {
            console.log("Verification failed (manual verification may be needed)");
        }
    }

    function buildVerifyCommand(address contractAddress, bytes memory) internal view returns (string[] memory) {
        string[] memory cmd = new string[](4);
        cmd[0] = "forge";
        cmd[1] = "verify-contract";
        cmd[2] = vm.toString(contractAddress);
        cmd[3] = string.concat("--chain-id=", vm.toString(block.chainid));

        return cmd;
    }

    // ============================================================
    // BROADCAST HELPERS
    // ============================================================

    function startBroadcastWith(uint256 privateKey) internal {
        bool shouldBroadcast = getEnvBoolOr("BROADCAST", false);

        if (shouldBroadcast) {
            vm.startBroadcast(privateKey);
            console.log("Broadcasting transactions...");
        } else {
            console.log("Simulation mode (BROADCAST=false)");
        }
    }

    function stopBroadcastIf() internal {
        bool shouldBroadcast = getEnvBoolOr("BROADCAST", false);
        if (shouldBroadcast) {
            vm.stopBroadcast();
        }
    }
}
