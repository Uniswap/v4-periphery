// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
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
import {IERC721} from "forge-std/interfaces/IERC721.sol";

import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {DeltaResolver} from "../../src/base/DeltaResolver.sol";
import {PositionConfig} from "../shared/PositionConfig.sol";
import {SlippageCheck} from "../../src/libraries/SlippageCheck.sol";
import {BaseActionsRouter} from "../../src/base/BaseActionsRouter.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";

import {LiquidityFuzzers} from "../shared/fuzz/LiquidityFuzzers.sol";
import {Planner, Plan} from "../shared/Planner.sol";
import {PosmTestSetup} from "../shared/PosmTestSetup.sol";
import {ReentrantToken} from "../mocks/ReentrantToken.sol";
import {ReentrancyLock} from "../../src/base/ReentrancyLock.sol";

contract SingleSidedTest is Test, PosmTestSetup, LiquidityFuzzers {
    using FixedPointMathLib for uint256;
    using StateLibrary for IPoolManager;

    PoolId poolId;
    address alice = makeAddr("ALICE");

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // This is needed to receive return deltas from modifyLiquidity calls.
        deployPosmHookSavesDelta();

        (key, poolId) = initPool(currency0, currency1, IHooks(hook), 3000, SQRT_PRICE_1_1);

        // tick is 0
        (, int24 tick,,) = manager.getSlot0(poolId);
        require(tick == 0);

        // Requires currency0 and currency1 to be set in base Deployers contract.
        deployAndApprovePosm(manager);

        seedBalance(alice);
        approvePosmFor(alice);
    }

    function test_singleSided_token0() public {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: 0, tickUpper: 60});
        bytes memory calls = getMintEncoded(config, 1e18, ActionConstants.MSG_SENDER, "");

        uint256 balance0Before = key.currency0.balanceOfSelf();
        uint256 balance1Before = key.currency1.balanceOfSelf();

        lpm.modifyLiquidities(calls, vm.getBlockTimestamp());

        uint256 balance0After = key.currency0.balanceOfSelf();
        uint256 balance1After = key.currency1.balanceOfSelf();

        // paid currency0
        assertGt(balance0Before - balance0After, 0);

        // did not spend currency1
        assertEq(balance1Before, balance1After);
    }

    function test_singleSided_token1() public {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -60, tickUpper: 0});
        bytes memory calls = getMintEncoded(config, 1e18, ActionConstants.MSG_SENDER, "");

        uint256 balance0Before = key.currency0.balanceOfSelf();
        uint256 balance1Before = key.currency1.balanceOfSelf();

        lpm.modifyLiquidities(calls, vm.getBlockTimestamp());

        uint256 balance0After = key.currency0.balanceOfSelf();
        uint256 balance1After = key.currency1.balanceOfSelf();

        // did not spend currency0
        assertEq(balance0Before, balance0After);

        // paid currency1
        assertGt(balance1Before - balance1After, 0);
    }

    function test_singleSided_withdraw() public {
        // Create position0 on range [0, 60] with token0
        PositionConfig memory config0 = PositionConfig({poolKey: key, tickLower: 0, tickUpper: 60});
        bytes memory calls0 = getMintEncoded(config0, 1e18, ActionConstants.MSG_SENDER, "");
        uint256 tokenId0 = lpm.nextTokenId();
        lpm.modifyLiquidities(calls0, vm.getBlockTimestamp());

        // Create position1 on range [-60, 0] with token1
        PositionConfig memory config1 = PositionConfig({poolKey: key, tickLower: -60, tickUpper: 0});
        bytes memory calls1 = getMintEncoded(config1, 1e18, ActionConstants.MSG_SENDER, "");
        uint256 tokenId1 = lpm.nextTokenId();
        lpm.modifyLiquidities(calls1, vm.getBlockTimestamp());

        // withdraw position0, receiving only currency0
        uint256 balance0Before = key.currency0.balanceOfSelf();
        uint256 balance1Before = key.currency1.balanceOfSelf();
        bytes memory burn0 = getBurnEncoded(tokenId0, config0, "");
        lpm.modifyLiquidities(burn0, vm.getBlockTimestamp());
        uint256 balance0After = key.currency0.balanceOfSelf();
        uint256 balance1After = key.currency1.balanceOfSelf();

        // received currency0
        assertGt(balance0After - balance0Before, 0);
        // did not receive currency1
        assertEq(balance1Before, balance1After);

        // withdraw position1, receiving only currency1
        balance0Before = key.currency0.balanceOfSelf();
        balance1Before = key.currency1.balanceOfSelf();
        bytes memory burn1 = getBurnEncoded(tokenId1, config1, "");
        lpm.modifyLiquidities(burn1, vm.getBlockTimestamp());
        balance0After = key.currency0.balanceOfSelf();
        balance1After = key.currency1.balanceOfSelf();

        // did not receive currency0
        assertEq(balance0Before, balance0After);
        // received currency1
        assertGt(balance1After - balance1Before, 0);
    }
}
