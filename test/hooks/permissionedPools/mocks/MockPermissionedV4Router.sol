// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PermissionedV4Router} from "../../../../src/hooks/permissionedPools/PermissionedV4Router.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IWrappedPermissionedTokenFactory} from
    "../../../../src/hooks/permissionedPools/interfaces/IWrappedPermissionedTokenFactory.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IMsgSender} from "../../../../src/interfaces/IMsgSender.sol";
import {V4Router} from "../../../../src/V4Router.sol";
import {ReentrancyLock} from "../../../../src/base/ReentrancyLock.sol";

contract MockPermissionedV4Router is PermissionedV4Router {
    using SafeTransferLib for *;

    constructor(
        IPoolManager poolManager_,
        IAllowanceTransfer _permit2,
        IWrappedPermissionedTokenFactory wrappedTokenFactory,
        address permissionedPositionManager,
        address delegateRouter_
    ) PermissionedV4Router(poolManager_, _permit2, wrappedTokenFactory, permissionedPositionManager, delegateRouter_) {}

    function setDelegateRouter(address _delegateRouter) public {
        delegateRouter = _delegateRouter;
    }

    function executeActionsAndSweepExcessETH(bytes calldata params) external payable isNotLocked {
        execute(params);

        uint256 balance = address(this).balance;
        if (balance > 0) {
            msg.sender.safeTransferETH(balance);
        }
    }

    receive() external payable {}
    fallback() external payable {}
}

contract MockV4Router is V4Router, ReentrancyLock {
    using SafeTransferLib for *;

    constructor(IPoolManager _poolManager) V4Router(_poolManager) {}

    function executeActions(bytes calldata params) external payable isNotLocked {
        _executeActions(params);
    }

    function executeActionsAndSweepExcessETH(bytes calldata params) external payable isNotLocked {
        _executeActions(params);

        uint256 balance = address(this).balance;
        if (balance > 0) {
            msg.sender.safeTransferETH(balance);
        }
    }

    function _pay(Currency token, address payer, uint256 amount) internal override {
        if (payer == address(this)) {
            token.transfer(address(poolManager), amount);
        } else {
            ERC20(Currency.unwrap(token)).safeTransferFrom(payer, address(poolManager), amount);
        }
    }

    function msgSender() public view override returns (address) {
        return _getLocker();
    }

    function beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        returns (bytes4)
    {
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata, bytes calldata)
        external
        view
        returns (bytes4)
    {
        return IHooks.beforeSwap.selector;
    }

    receive() external payable {}
}
