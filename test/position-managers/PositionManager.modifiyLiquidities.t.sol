// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {PositionManager} from "../../src/PositionManager.sol";
import {DeltaResolver} from "../../src/base/DeltaResolver.sol";
import {PositionConfig} from "../../src/libraries/PositionConfig.sol";
import {SlippageCheckLibrary} from "../../src/libraries/SlippageCheck.sol";
import {BaseActionsRouter} from "../../src/base/BaseActionsRouter.sol";
import {Constants} from "../../src/libraries/Constants.sol";

import {LiquidityFuzzers} from "../shared/fuzz/LiquidityFuzzers.sol";
import {Planner, Plan} from "../shared/Planner.sol";
import {PosmTestSetup} from "../shared/PosmTestSetup.sol";
import {ReentrantToken} from "../mocks/ReentrantToken.sol";
import {ReentrancyLock} from "../../src/base/ReentrancyLock.sol";

contract PositionManagerModifyLiquiditiesTest is Test, PosmTestSetup, LiquidityFuzzers {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    PoolId poolId;
    address alice;
    uint256 alicePK;
    address bob;

    PositionConfig config;

    function setUp() public {
        (alice, alicePK) = makeAddrAndKey("ALICE");
        (bob,) = makeAddrAndKey("BOB");

        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // Requires currency0 and currency1 to be set in base Deployers contract.
        deployAndApprovePosm(manager);

        seedBalance(alice);
        approvePosmFor(alice);

        // must deploy after posm
        // Deploys a hook which can accesses IPositionManager.modifyLiquidities
        deployPosmHookModifyLiquidities();
        seedBalance(address(hookModifyLiquidities));

        (key, poolId) = initPool(currency0, currency1, IHooks(hookModifyLiquidities), 3000, SQRT_PRICE_1_1, ZERO_BYTES);

        config = PositionConfig({poolKey: key, tickLower: -60, tickUpper: 60});
    }

    function test_hook_increaseLiquidity() public {
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, address(this), ZERO_BYTES);

        // hook increases liquidity in beforeSwap via hookData
        uint256 newLiquidity = 10e18;
        bytes memory calls = getIncreaseEncoded(tokenId, config, newLiquidity, ZERO_BYTES);

        swap(key, true, -1e18, calls);

        bytes32 positionId =
            Position.calculatePositionKey(address(lpm), config.tickLower, config.tickUpper, bytes32(tokenId));
        (uint256 liquidity,,) = manager.getPositionInfo(config.poolKey.toId(), positionId);

        assertEq(liquidity, initialLiquidity + newLiquidity);
    }

    function test_hook_decreaseLiquidity() public {}
    function test_hook_collect() public {}
    function test_hook_burn() public {}

    function test_hook_increaseLiquidity_revert() public {}
    function test_hook_decreaseLiquidity_revert() public {}
    function test_hook_collect_revert() public {}
    function test_hook_burn_revert() public {}
}
