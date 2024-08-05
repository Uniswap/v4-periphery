// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {BaseHook} from "./../../src/base/hooks/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

// @notice This contract is used to test griefing via returning large amounts of data
contract RemoveGriefs is BaseHook {
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    // Middleware implementations do not need to be mined
    function validateHookAddress(BaseHook _this) internal pure override {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view override returns (bytes4) {
        returnLotsOfData();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        bytes calldata
    ) external view override returns (bytes4, BalanceDelta) {
        returnLotsOfData();
    }

    function returnLotsOfData() internal view {
        bytes memory largeData = new bytes(320000); // preallocate memory for efficiency
        bytes32 tempData;
        uint256 i = 0;
        while (true) {
            unchecked {
                ++i;
            }
            tempData = bytes32(i);
            assembly {
                mstore(add(largeData, add(32, mul(i, 32))), tempData)
            }
            if (gasleft() < 100_000) break;
        }
        assembly {
            let len := mul(i, 32)
            mstore(largeData, len)
            return(add(largeData, 32), len)
        }
    }
}
