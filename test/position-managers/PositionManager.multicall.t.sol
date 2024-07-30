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
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {PositionManager} from "../../src/PositionManager.sol";
import {PositionConfig} from "../../src/libraries/PositionConfig.sol";
import {IMulticall} from "../../src/interfaces/IMulticall.sol";
import {LiquidityFuzzers} from "../shared/fuzz/LiquidityFuzzers.sol";
import {Planner, Plan} from "../shared/Planner.sol";
import {PosmTestSetup} from "../shared/PosmTestSetup.sol";

contract PositionManagerMulticallTest is Test, PosmTestSetup, LiquidityFuzzers {
    using FixedPointMathLib for uint256;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using Planner for Plan;

    PoolId poolId;
    address alice;
    uint256 alicePK;
    address bob;

    function setUp() public {
        (alice, alicePK) = makeAddrAndKey("ALICE");
        (bob,) = makeAddrAndKey("BOB");

        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        (key, poolId) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1, ZERO_BYTES);

        // Requires currency0 and currency1 to be set in base Deployers contract.
        deployAndApprovePosm(manager);

        seedBalance(alice);
        seedBalance(bob);

        approvePosmFor(alice);
        approvePosmFor(bob);
    }

    function test_multicall_initializePool_mint() public {
        key = PoolKey({currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 10, hooks: IHooks(address(0))});

        // Use multicall to initialize a pool and mint liquidity
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(lpm.initializePool.selector, key, SQRT_PRICE_1_1, ZERO_BYTES);

        PositionConfig memory config = PositionConfig({
            poolKey: key,
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing)
        });

        Plan memory planner = Planner.init();
        planner.add(Actions.MINT_POSITION, abi.encode(config, 100e18, address(this), ZERO_BYTES));
        bytes memory actions = planner.finalizeModifyLiquidity(config.poolKey);

        calls[1] = abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector, actions, _deadline);

        IMulticall(address(lpm)).multicall(calls);

        // test swap, doesn't revert, showing the pool was initialized
        int256 amountSpecified = -1e18;
        BalanceDelta result = swap(key, true, amountSpecified, ZERO_BYTES);
        assertEq(result.amount0(), amountSpecified);
        assertGt(result.amount1(), 0);
    }

    function test_multicall_permitAndDecrease() public {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -60, tickUpper: 60});
        uint256 liquidityAlice = 1e18;
        vm.startPrank(alice);
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        vm.stopPrank();
        uint256 tokenId = lpm.nextTokenId() - 1;

        // Alice gives Bob permission to operate on her liquidity
        uint256 nonce = 1;
        bytes32 digest = getDigest(bob, tokenId, nonce, block.timestamp + 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);

        // bob gives himself permission and decreases liquidity
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(
            PositionManager(lpm).permit.selector, bob, tokenId, block.timestamp + 1, nonce, v, r, s
        );
        uint256 liquidityToRemove = 0.4444e18;
        bytes memory actions = getDecreaseEncoded(tokenId, config, liquidityToRemove, ZERO_BYTES);
        calls[1] = abi.encodeWithSelector(PositionManager(lpm).modifyLiquidities.selector, actions, _deadline);

        vm.prank(bob);
        lpm.multicall(calls);

        bytes32 positionId =
            keccak256(abi.encodePacked(address(lpm), config.tickLower, config.tickUpper, bytes32(tokenId)));
        (uint256 liquidity,,) = manager.getPositionInfo(config.poolKey.toId(), positionId);
        assertEq(liquidity, liquidityAlice - liquidityToRemove);
    }
}
