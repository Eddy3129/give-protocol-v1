// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ForkAddresses} from "./ForkAddresses.sol";

/// @title ForkBase
/// @notice Shared base for all fork tests. Skips gracefully when BASE_RPC_URL is not set
///         so CI without RPC credentials still passes.
abstract contract ForkBase is Test {
    uint256 internal fork;
    bool internal _forkActive;

    function setUp() public virtual {
        string memory rpcUrl = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            _forkActive = false;
            return;
        }
        fork = vm.createFork(rpcUrl);
        vm.selectFork(fork);
        _forkActive = true;
    }

    /// @dev Call at the top of every test to skip cleanly when no RPC is available.
    modifier requiresFork() {
        if (!_forkActive) {
            vm.skip(true);
            return;
        }
        _;
    }

    /// @dev Fund `recipient` with `amount` of USDC using Foundry's deal cheatcode.
    function _dealUsdc(address recipient, uint256 amount) internal {
        deal(ForkAddresses.USDC, recipient, amount);
    }
}
