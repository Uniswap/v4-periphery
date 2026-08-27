// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ISwapAndAdd} from "../../../src/interfaces/ISwapAndAdd.sol";

/// @notice ABI for `SwapAndAddHarness`. Tests must not import the harness source (compiled via_ir).
///         `CoreParams` field order matches the production struct in `SwapAndAdd`.
interface ISwapAndAddHarness is ISwapAndAdd {
    struct CoreParams {
        uint256 deployTokenId;
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint256 budget0;
        uint256 budget1;
        bytes route;
        uint256 minLiquidity;
        address recipient;
        bytes hookData;
    }

    function exposedDeployLiquidity(CoreParams calldata cp, uint128 liquidity, uint256 amount0)
        external
        payable
        returns (uint256 tokenId);

    function exposedReconcile(
        CoreParams calldata cp,
        uint256 tokenId,
        uint128 lopt,
        uint256 a0opt,
        uint256 a1opt,
        uint160 sqrtLower,
        uint160 sqrtUpper,
        uint256 take0,
        uint256 take1,
        address take0To,
        address take1To
    ) external payable returns (uint128 trimmed);

    function exposedFlashTakeDeficit(CoreParams calldata cp, uint256 amount0, uint256 amount1)
        external
        payable
        returns (int256 delta0, int256 delta1);

    function exposedTrim(
        CoreParams calldata cp,
        uint256 tokenId,
        uint128 lopt,
        bool deficitIsCurrency1,
        uint256 amountOut,
        uint160 sqrtLower,
        uint160 sqrtUpper
    ) external payable returns (uint128 dl);

    function exposedSettleToward(Currency currency, uint256 takeAmount, address takeTo)
        external
        payable
        returns (int256 deltaBefore, int256 deltaAfter, uint256 heldBefore, uint256 heldAfter);

    function exposedTakeCredit(Currency currency, bool createCredit)
        external
        payable
        returns (int256 deltaBefore, int256 deltaAfter, uint256 heldBefore, uint256 heldAfter);

    function exposedSwapAndAdd(CoreParams calldata cp)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    function exposedDecrease(PoolKey calldata key, uint256 tokenId, uint128 dl, bytes calldata hookData)
        external
        payable;

    function exposedPlanLiquidity(CoreParams calldata cp, uint160 sqrtLower, uint160 sqrtUpper)
        external
        view
        returns (uint128 liquidity, uint256 amount0, uint256 amount1);

    function exposedExecuteRoute(CoreParams calldata cp) external payable;

    function exposedPull(
        PoolKey calldata key,
        uint256 amount0In,
        uint256 amount1In,
        ISwapAndAdd.TokenAmount[] calldata funding,
        bytes calldata route
    ) external payable;

    function exposedSweepFunding(ISwapAndAdd.TokenAmount[] calldata funding, address to) external;

    function exposedSweep(Currency currency, address to) external;

    function exposedEnsureApproved(Currency currency) external;

    function exposedResolveBudget(Currency currency, int128 delta, address recipient) external returns (uint256 budget);

    function exposedValidateRecipient(address recipient) external view;

    function exposedAuthAndResolveRecipient(uint256 tokenId, address requested) external view returns (address);

    function exposedBurnAndWithdraw(PoolKey calldata key, uint256 tokenId, bytes calldata hookData) external;
}
