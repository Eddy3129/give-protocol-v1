// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";
import {DataTypes} from "@aave/core-v3/contracts/protocol/libraries/types/DataTypes.sol";

import {ForkBase} from "./ForkBase.t.sol";
import {ForkAddresses} from "./ForkAddresses.sol";

/// @title ForkSanity
/// @notice Verifies that the fork is connected to Base mainnet and that the
///         external contracts we depend on are deployed at expected addresses.
///         Run these before the more expensive adapter/vault tests.
contract ForkSanity is ForkBase {
    IPool internal pool;

    function setUp() public override {
        super.setUp();
        pool = IPool(ForkAddresses.AAVE_POOL);
    }

    function test_fork_is_base_mainnet() public requiresFork {
        assertEq(block.chainid, ForkAddresses.CHAIN_ID, "not Base mainnet");
        assertGt(block.number, 0, "block.number is 0");
    }

    function test_aave_pool_has_code() public requiresFork {
        assertGt(
            ForkAddresses.AAVE_POOL.code.length,
            0,
            "Aave V3 pool not deployed at expected address"
        );
    }

    function test_usdc_has_code() public requiresFork {
        assertGt(ForkAddresses.USDC.code.length, 0, "USDC not deployed");
    }

    function test_ausdc_has_code() public requiresFork {
        assertGt(ForkAddresses.AUSDC.code.length, 0, "aUSDC not deployed");
    }

    function test_usdc_reserve_is_active_and_not_frozen() public requiresFork {
        DataTypes.ReserveData memory data = pool.getReserveData(ForkAddresses.USDC);
        DataTypes.ReserveConfigurationMap memory cfg = data.configuration;
        // Aave config bit layout: bit 0 = isActive, bit 1 = isFrozen
        assertTrue(cfg.data & 1 == 1,      "USDC reserve is not active");
        assertTrue(cfg.data >> 1 & 1 == 0, "USDC reserve is frozen");
    }

    function test_ausdc_address_matches_reserve_data() public requiresFork {
        DataTypes.ReserveData memory data = pool.getReserveData(ForkAddresses.USDC);
        assertEq(
            data.aTokenAddress,
            ForkAddresses.AUSDC,
            "aUSDC address mismatch with ForkAddresses constant"
        );
    }

    function test_deal_usdc_works() public requiresFork {
        uint256 amount = 100_000e6;
        _dealUsdc(address(this), amount);
        assertEq(IERC20(ForkAddresses.USDC).balanceOf(address(this)), amount);
    }
}
