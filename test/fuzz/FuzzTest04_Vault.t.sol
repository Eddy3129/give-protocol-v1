// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title   FuzzTest04_Vault
 * @author  GIVE Labs
 * @notice  Stateful property-based fuzzing for GiveVault4626 deposit/redeem cycle
 * @dev     Tests multi-step vault interactions with arbitrary amounts and adapters:
 *          - Deposit: arbitrary amount deposited, share minting, adapter investment
 *          - Harvest: arbitrary yield from adapter, share accumulator update
 *          - Redeem: arbitrary share burns, divest from adapter, user asset return
 *          - Invariants: totalSupply consistency, underlying asset tracking, adapter sync
 */

import {Base02_DeployVaultsAndAdapters} from "../base/Base02_DeployVaultsAndAdapters.t.sol";
import {StrategyRegistry} from "../../src/registry/StrategyRegistry.sol";
import {CampaignRegistry} from "../../src/registry/CampaignRegistry.sol";

contract FuzzTest04_Vault is Base02_DeployVaultsAndAdapters {
    bytes32 private _fuzzStrategyId;
    bytes32 private _fuzzCampaignId;

    function setUp() public override {
        super.setUp();

        vm.startPrank(strategyAdmin);
        usdcVaultManager.setActiveAdapter(address(mockUsdcAdapter));
        vm.stopPrank();

        _fuzzStrategyId = keccak256("fuzz.strategy.usdc");
        _fuzzCampaignId = keccak256("fuzz.campaign.usdc");

        vm.prank(strategyAdmin);
        strategyRegistry.registerStrategy(
            StrategyRegistry.StrategyInput({
                id: _fuzzStrategyId,
                adapter: address(mockUsdcAdapter),
                riskTier: keccak256("LOW"),
                maxTvl: 50_000_000e6,
                metadataHash: keccak256("fuzz.strategy")
            })
        );

        vm.prank(campaignCreator);
        campaignRegistry.submitCampaign{value: 0.005 ether}(
            CampaignRegistry.CampaignInput({
                id: _fuzzCampaignId,
                payoutRecipient: ngo1,
                strategyId: _fuzzStrategyId,
                metadataHash: keccak256("fuzz.campaign"),
                metadataCID: "QmFuzzCampaign",
                targetStake: 1_000_000e6,
                minStake: 100e6,
                fundraisingStart: uint64(block.timestamp),
                fundraisingEnd: uint64(block.timestamp + 30 days)
            })
        );

        vm.prank(campaignAdmin);
        campaignRegistry.approveCampaign(_fuzzCampaignId, campaignAdmin);

        vm.startPrank(admin);
        payoutRouter.grantRole(payoutRouter.VAULT_MANAGER_ROLE(), admin);
        payoutRouter.setAuthorizedCaller(address(usdcVault), true);
        payoutRouter.registerCampaignVault(address(usdcVault), _fuzzCampaignId);
        usdcVault.setDonationRouter(address(payoutRouter));
        vm.stopPrank();
    }

    function testFuzz_deposit_withdraw_roundtrip(uint256 assets, address receiver) public {
        uint256 boundedAssets = bound(assets, 1e6, 100_000e6);

        // Exclude zero address and deployed system contracts that would cause
        // self-referential calls (e.g. vault depositing into itself).
        vm.assume(receiver != address(0));
        vm.assume(receiver != address(usdcVault));
        vm.assume(receiver != address(payoutRouter));
        vm.assume(receiver != address(usdc));
        address user = receiver;

        usdc.mint(user, boundedAssets);

        vm.startPrank(user);
        usdc.approve(address(usdcVault), boundedAssets);
        uint256 mintedShares = usdcVault.deposit(boundedAssets, user);
        uint256 withdrawnAssets = usdcVault.redeem(mintedShares, user, user);
        vm.stopPrank();

        // No-loss adapter: withdrawn amount must equal deposited amount within 1 wei rounding.
        assertApproxEqAbs(withdrawnAssets, boundedAssets, 1);
    }

    function testFuzz_multiple_depositors(uint8 numUsers, uint256[8] calldata amounts) public {
        uint256 userCount = bound(uint256(numUsers), 1, 8);
        uint256 expectedTotalShares;
        uint256 observedTotalShares;

        for (uint256 i = 0; i < userCount; i++) {
            address user = vm.addr(10_000 + i);
            uint256 amount = bound(amounts[i], 1e6, 25_000e6);

            usdc.mint(user, amount);
            vm.startPrank(user);
            usdc.approve(address(usdcVault), amount);
            expectedTotalShares += usdcVault.deposit(amount, user);
            vm.stopPrank();
        }

        for (uint256 i = 0; i < userCount; i++) {
            observedTotalShares += usdcVault.balanceOf(vm.addr(10_000 + i));
        }

        assertEq(observedTotalShares, usdcVault.totalSupply());
        assertEq(expectedTotalShares, usdcVault.totalSupply());

        uint256 cashBalance = usdcVault.getCashBalance();
        uint256 adapterAssets = usdcVault.getAdapterAssets();
        assertEq(cashBalance + adapterAssets, usdcVault.totalAssets());
    }

    function testFuzz_share_price_nondecreasing(uint256 yieldAmount) public {
        uint256 boundedYield = bound(yieldAmount, 1e6, 5_000_000e6);

        vm.startPrank(donor1);
        usdc.approve(address(usdcVault), 50_000e6);
        usdcVault.deposit(50_000e6, donor1);
        vm.stopPrank();

        uint256 beforeAssetsPerShare = usdcVault.previewRedeem(1e6);

        usdc.mint(admin, boundedYield);
        vm.startPrank(admin);
        usdc.approve(address(mockUsdcAdapter), boundedYield);
        mockUsdcAdapter.addYield(boundedYield);
        vm.stopPrank();

        usdcVault.harvest();

        uint256 afterAssetsPerShare = usdcVault.previewRedeem(1e6);
        assertGe(afterAssetsPerShare, beforeAssetsPerShare);
    }

    function testFuzz_cash_buffer_enforcement(uint256 assets, uint16 bufferBps) public {
        uint256 boundedAssets = bound(assets, 1e6, 100_000e6);
        uint256 boundedBufferBps = bound(uint256(bufferBps), 0, usdcVault.MAX_CASH_BUFFER_BPS());

        vm.prank(admin);
        usdcVault.setCashBufferBps(boundedBufferBps);

        vm.startPrank(donor2);
        usdc.approve(address(usdcVault), boundedAssets);
        usdcVault.deposit(boundedAssets, donor2);
        vm.stopPrank();

        uint256 cashBalance = usdcVault.getCashBalance();
        uint256 targetCash = (usdcVault.totalAssets() * boundedBufferBps) / 10_000;
        assertLe(cashBalance, targetCash + 1);
    }
}
