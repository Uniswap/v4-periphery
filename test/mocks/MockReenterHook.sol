// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BaseTestHooks} from "@uniswap/v4-core/src/test/BaseTestHooks.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

contract MockReenterHook is BaseTestHooks {
    IPositionManager posm;

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata functionSelector
    ) external override returns (bytes4) {
        if (functionSelector.length == 0) {
            return this.beforeAddLiquidity.selector;
        }
        (bytes4 selector, address owner, uint256 tokenId) = abi.decode(functionSelector, (bytes4, address, uint256));

        if (selector == IERC721(address(posm)).transferFrom.selector) {
            IERC721(address(posm)).transferFrom(owner, address(this), tokenId);
        } else if (selector == posm.subscribe.selector) {
            posm.subscribe(tokenId, address(this), "");
        } else if (selector == posm.unsubscribe.selector) {
            posm.unsubscribe(tokenId);
        }
        return this.beforeAddLiquidity.selector;
    }

    function setPosm(IPositionManager _posm) external {
        posm = _posm;
    }
}
