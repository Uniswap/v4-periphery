// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {RouterParameters} from "universal-router/contracts/types/RouterParameters.sol";
import {Commands} from "universal-router/contracts/libraries/Commands.sol";

import {IWETH9} from "../../src/interfaces/external/IWETH9.sol";

import {IV4Router} from "../../src/interfaces/IV4Router.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";

/// @notice Shared helpers for margin tests that route position swaps through the Universal Router.
///         Deploys a UR bound to a local PoolManager and builds the UR command plan for a single-pool
///         v4 exact-output swap, so the curated `increasePosition`/`decreasePosition` flows (which now
///         route through `ROUTE_SWAP`) can be driven over the tests' local v4 pools. Routing a v4 swap
///         through UR inside the router's own unlock exercises UR's already-unlocked `V4_SWAP` path.
abstract contract MarginRouteHelpers is Test {
    /// @notice Deploys a UniversalRouter bound to `manager`, `permit2`, and `weth9`. The v2/v3
    ///         factories are left zero because the helper routes only over v4 pools; `vm.getCode` reads
    ///         UR's own (via_ir) artifact so the concrete contract is never pulled into the test's
    ///         compilation profile.
    function deployUniversalRouter(address manager, address permit2, address weth9) internal returns (address ur) {
        RouterParameters memory p;
        p.permit2 = permit2;
        p.weth9 = weth9;
        p.v4PoolManager = manager;
        bytes memory initcode = abi.encodePacked(vm.getCode("UniversalRouter.sol:UniversalRouter"), abi.encode(p));
        assembly {
            ur := create(0, add(initcode, 0x20), mload(initcode))
        }
        require(ur != address(0), "UR deploy failed");
    }

    /// @notice Deploys a MarginRouter from its own compiled artifact via `vm.getCode`, so the router's
    ///         source is never pulled into a test's (via_ir=false) compilation profile — the same reason
    ///         `deployUniversalRouter` uses `getCode`. This lets MarginRouter be pinned to a smaller
    ///         optimizer-runs profile (which fits under the EIP-170 runtime size limit) without a
    ///         source-level construction in a test forcing it to co-compile at the test profile. Returns
    ///         the raw address; cast it to `MarginRouter` at the call site.
    function deployMarginRouter(
        IPoolManager poolManager,
        IAllowanceTransfer permit2,
        IWETH9 weth9,
        address accountImplementation,
        address governance,
        address universalRouter
    ) internal returns (address router) {
        bytes memory args = abi.encode(poolManager, permit2, weth9, accountImplementation, governance, universalRouter);
        bytes memory initcode = abi.encodePacked(vm.getCode("MarginRouter.sol:MarginRouter"), args);
        assembly {
            router := create(0, add(initcode, 0x20), mload(initcode))
        }
        require(router != address(0), "MarginRouter deploy failed");
    }

    /// @notice Builds a UR command plan for a single v4 exact-output swap: buy `amountOut` of `output`
    ///         for at most `maxIn` of `input` over `poolKey`, pulling the input from the router (the UR
    ///         caller) via Permit2 and delivering the output to `recipient`.
    /// @param poolKey The v4 pool to swap through.
    /// @param input The currency spent (the router grants UR a Permit2 allowance of it in `ROUTE_SWAP`).
    /// @param output The currency bought.
    /// @param amountOut The exact output amount to buy.
    /// @param maxIn The maximum input (the swap's `amountInMaximum`; the binding cap is the router's
    ///        Permit2 allowance, also `maxIn`).
    /// @param recipient The address the bought output is delivered to (the MarginAccount).
    /// @return commands The Universal Router command byte string.
    /// @return inputs The per-command inputs.
    function buildV4ExactOutRoute(
        PoolKey memory poolKey,
        Currency input,
        Currency output,
        uint128 amountOut,
        uint128 maxIn,
        address recipient
    ) internal pure returns (bytes memory commands, bytes[] memory inputs) {
        return buildV4ExactOutRoute(poolKey, input, output, amountOut, maxIn, recipient, 0);
    }

    /// @notice As above, with an explicit `minHopPriceX36` per-hop price bound forwarded into the v4
    ///         swap (0 disables it). Used by the price-guard tests.
    function buildV4ExactOutRoute(
        PoolKey memory poolKey,
        Currency input,
        Currency output,
        uint128 amountOut,
        uint128 maxIn,
        address recipient,
        uint256 minHopPriceX36
    ) internal pure returns (bytes memory commands, bytes[] memory inputs) {
        // selling `input` to buy `output`: zeroForOne when the input is the pool's currency0
        bool zeroForOne = Currency.unwrap(input) == Currency.unwrap(poolKey.currency0);

        bytes memory v4Actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_OUT_SINGLE), uint8(Actions.SETTLE), uint8(Actions.TAKE));
        bytes[] memory v4Params = new bytes[](3);
        v4Params[0] = abi.encode(
            IV4Router.ExactOutputSingleParams({
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                amountOut: amountOut,
                amountInMaximum: maxIn,
                minHopPriceX36: minHopPriceX36,
                hookData: ""
            })
        );
        // settle the swap input from the router (the UR caller) via Permit2
        v4Params[1] = abi.encode(input, uint256(ActionConstants.OPEN_DELTA), true);
        // take the bought output to the recipient (the MarginAccount)
        v4Params[2] = abi.encode(output, recipient, uint256(ActionConstants.OPEN_DELTA));

        commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        inputs = new bytes[](1);
        inputs[0] = abi.encode(v4Actions, v4Params);
    }
}
