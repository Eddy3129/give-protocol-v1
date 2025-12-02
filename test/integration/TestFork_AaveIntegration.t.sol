// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/adapters/AaveAdapter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AaveV3BaseSepolia, AaveV3BaseSepoliaAssets} from "lib/aave-address-book/src/AaveV3BaseSepolia.sol";

/**
 * @title TestFork_AaveIntegration
 * @notice Integration test for AaveAdapter using Base Sepolia fork
 * @dev Tests interaction with real Aave V3 contracts on Base Sepolia
 *      Run with: forge test --match-contract TestFork_AaveIntegration --fork-url $BASE_SEPOLIA_RPC_URL
 */
contract TestFork_AaveIntegration is Test {
    // Base Sepolia Addresses
    address constant USDC = AaveV3BaseSepoliaAssets.USDC_UNDERLYING;
    address constant AAVE_POOL = address(AaveV3BaseSepolia.POOL);

    AaveAdapter public adapter;
    address public vault;
    address public admin;

    function setUp() public {
        if (block.chainid == 31337) {
            string memory forkUrl = vm.envOr("BASE_SEPOLIA_RPC_URL", string(""));
            if (bytes(forkUrl).length == 0) {
                vm.skip(true);
            }
            vm.createSelectFork(forkUrl);
        }

        vault = makeAddr("vault");
        admin = makeAddr("admin");

        // Deploy adapter
        adapter = new AaveAdapter(USDC, vault, AAVE_POOL, admin);

        // Deal USDC to vault (simulating deposits)
        // We use deal to give the vault USDC directly
        deal(USDC, vault, 100_000 * 1e6); // 100k USDC
    }

    function test_Fork_Aave_InvestAndDivest() public {
        uint256 investAmount = 1000 * 1e6; // 1000 USDC

        // 1. Invest
        vm.startPrank(vault);
        IERC20(USDC).transfer(address(adapter), investAmount);
        adapter.invest(investAmount);
        vm.stopPrank();

        // Check adapter state
        (address pool, address aTokenAddr,,) = adapter.getAaveInfo();
        assertEq(pool, AAVE_POOL, "Pool address mismatch");

        uint256 aTokenBalance = IERC20(aTokenAddr).balanceOf(address(adapter));
        assertGe(aTokenBalance, investAmount - 100, "aToken balance too low (rounding)");

        console.log("Invested:", investAmount);
        console.log("aToken Balance:", aTokenBalance);

        // 2. Simulate time passing (1 day)
        vm.warp(block.timestamp + 1 days);

        // 3. Harvest (might be 0 on testnet if no borrowers, but shouldn't revert)
        vm.prank(vault);
        (uint256 profit, uint256 loss) = adapter.harvest();

        console.log("Harvested Profit:", profit);
        console.log("Harvested Loss:", loss);

        // 4. Divest
        uint256 divestAmount = 500 * 1e6;
        vm.prank(vault);
        uint256 returned = adapter.divest(divestAmount);

        assertGe(returned, divestAmount, "Divest returned less than requested");
        console.log("Divested:", returned);

        // Check remaining balance
        uint256 remainingAToken = IERC20(aTokenAddr).balanceOf(address(adapter));
        console.log("Remaining aToken:", remainingAToken);
        assertGt(remainingAToken, 0, "Should have remaining balance");
    }

    function test_Fork_Aave_EmergencyWithdraw() public {
        uint256 investAmount = 1000 * 1e6;

        // Invest
        vm.startPrank(vault);
        IERC20(USDC).transfer(address(adapter), investAmount);
        adapter.invest(investAmount);
        vm.stopPrank();

        // Emergency Withdraw
        vm.prank(admin); // Admin has EMERGENCY_ROLE
        uint256 withdrawn = adapter.emergencyWithdraw();

        assertGe(withdrawn, investAmount - 100, "Emergency withdraw failed");

        (,, bool emergencyMode) = adapter.getRiskParameters();
        assertTrue(emergencyMode, "Should be in emergency mode");

        console.log("Emergency Withdrawn:", withdrawn);
    }
}
