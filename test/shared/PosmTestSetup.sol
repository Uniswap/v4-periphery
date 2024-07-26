// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PositionManager} from "../../src/PositionManager.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {LiquidityOperations} from "./LiquidityOperations.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";

/// @notice A shared test contract that wraps the v4-core deployers contract and exposes basic liquidity operations on posm.
contract PosmTestSetup is Test, Deployers, DeployPermit2, LiquidityOperations {
    uint256 constant STARTING_USER_BALANCE = 10_000_000 ether;

    IAllowanceTransfer permit2;

    function deployAndApprovePosm(IPoolManager poolManager) public {
        deployPosm(poolManager);
        approvePosm();
    }

    function deployPosm(IPoolManager poolManager) public {
        // We use deployPermit2() to prevent having to use via-ir in this repository.
        permit2 = IAllowanceTransfer(deployPermit2());
        lpm = new PositionManager(poolManager, permit2);
    }

    function seedBalance(address to) public {
        IERC20(Currency.unwrap(currency0)).transfer(to, STARTING_USER_BALANCE);
        IERC20(Currency.unwrap(currency1)).transfer(to, STARTING_USER_BALANCE);
    }

    function approvePosm() public {
        // Because POSM uses permit2, we must execute 2 permits/approvals.
        // 1. First, the caller must approve permit2 on the token.
        _approvePermit2AsASpender();
        // 2. Then, the caller must approve POSM as a spender of permit2. TODO: This could also be a signature.
        _approvePosmAsASpender();
    }

    function approvePosmNative() public {
        // Assumes currency0 is the native token so only execute approvals for currency1.
        IERC20(Currency.unwrap(currency1)).approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(currency1), address(lpm), type(uint160).max, type(uint48).max);
    }

    // Does the same approvals as approvePosm, but for a specific address.
    function approvePosmFor(address addr) public {
        vm.startPrank(addr);
        _approvePermit2AsASpender();
        _approvePosmAsASpender();
        vm.stopPrank();
    }

    function _approvePermit2AsASpender() internal {
        IERC20(Currency.unwrap(currency0)).approve(address(permit2), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(permit2), type(uint256).max);
    }

    function _approvePosmAsASpender() internal {
        permit2.approve(Currency.unwrap(currency0), address(lpm), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(lpm), type(uint160).max, type(uint48).max);
    }
}
