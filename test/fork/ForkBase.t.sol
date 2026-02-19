// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ForkAddresses} from "./ForkAddresses.sol";

/// @title ForkBase
/// @notice Shared base for all fork tests.
///         Uses BASE_RPC_URL env var if set (e.g. Alchemy for higher rate limits),
///         falling back to the public Base RPC so tests run without any configuration.
abstract contract ForkBase is Test {
    /// @dev Public Base mainnet RPC — no API key required, rate-limited.
    ///      Set BASE_RPC_URL in .env to override with a private endpoint.
    string internal constant PUBLIC_BASE_RPC = "https://base-rpc.publicnode.com";

    uint256 internal fork;
    bool internal _forkActive;

    function setUp() public virtual {
        string memory rpcUrl = vm.envOr("BASE_RPC_URL", PUBLIC_BASE_RPC);
        fork = vm.createFork(rpcUrl);
        vm.selectFork(fork);
        _forkActive = true;
    }

    /// @dev Guard for tests that require a live fork.
    ///      With the public RPC fallback this is always active, but kept for
    ///      explicit documentation and potential future conditional skipping.
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
