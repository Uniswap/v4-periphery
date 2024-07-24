// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPositionManager, Actions} from "../../src/interfaces/IPositionManager.sol";
import {PositionManager} from "../../src/PositionManager.sol";
import {LiquidityRange} from "../../src/types/LiquidityRange.sol";
import {IMulticall} from "../../src/interfaces/IMulticall.sol";
import {Planner} from "../utils/Planner.sol";
import {PosmTestSetup} from "../shared/PosmTestSetup.sol";

contract GasTest is Test, PosmTestSetup, GasSnapshot {
    using FixedPointMathLib for uint256;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using Planner for Planner.Plan;

    PoolId poolId;
    address alice;
    uint256 alicePK;
    address bob;
    uint256 bobPK;

    // expresses the fee as a wad (i.e. 3000 = 0.003e18 = 0.30%)
    uint256 FEE_WAD;

    LiquidityRange range;
    LiquidityRange nativeRange;

    function setUp() public {
        (alice, alicePK) = makeAddrAndKey("ALICE");
        (bob, bobPK) = makeAddrAndKey("BOB");

        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        (key, poolId) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1, ZERO_BYTES);
        (nativeKey,) = initPool(CurrencyLibrary.NATIVE, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1, ZERO_BYTES);
        FEE_WAD = uint256(key.fee).mulDivDown(FixedPointMathLib.WAD, 1_000_000);

        // Requires currency0 and currency1 to be set in base Deployers contract.
        deployAndApprovePosm(manager);

        // Give tokens to Alice and Bob.
        seedBalance(alice);
        seedBalance(bob);

        // Approve posm for Alice and bob.
        approvePosmFor(alice);
        approvePosmFor(bob);

        // define a reusable range
        range = LiquidityRange({poolKey: key, tickLower: -300, tickUpper: 300});
        nativeRange = LiquidityRange({poolKey: nativeKey, tickLower: -300, tickUpper: 300});
    }

    function test_gas_mint() public {
        Planner.Plan memory planner =
            Planner.init().add(Actions.MINT, abi.encode(range, 10_000 ether, address(this), ZERO_BYTES));
        bytes memory calls = planner.finalize(range.poolKey);
        lpm.modifyLiquidities(calls, _deadline);
        snapLastCall("PositionManager_mint");
    }

    function test_gas_mint_differentRanges() public {
        // Explicitly mint to a new range on the same pool.
        LiquidityRange memory bob_mint = LiquidityRange({poolKey: key, tickLower: 0, tickUpper: 60});
        vm.startPrank(bob);
        mint(bob_mint, 10_000 ether, address(bob), ZERO_BYTES);
        vm.stopPrank();
        // Mint to a diff range, diff user.
        Planner.Plan memory planner =
            Planner.init().add(Actions.MINT, abi.encode(range, 10_000 ether, address(alice), ZERO_BYTES));
        bytes memory calls = planner.finalize(range.poolKey);
        vm.prank(alice);
        lpm.modifyLiquidities(calls, _deadline);
        snapLastCall("PositionManager_mint_warmedPool_differentRange");
    }

    function test_gas_mint_sameTickLower() public {
        // Explicitly mint to range whos tickLower is the same.
        LiquidityRange memory bob_mint = LiquidityRange({poolKey: key, tickLower: range.tickLower, tickUpper: -60});
        vm.startPrank(bob);
        mint(bob_mint, 10_000 ether, address(bob), ZERO_BYTES);
        vm.stopPrank();
        // Mint to a diff range, diff user.
        Planner.Plan memory planner =
            Planner.init().add(Actions.MINT, abi.encode(range, 10_000 ether, address(alice), ZERO_BYTES));
        bytes memory calls = planner.finalize(range.poolKey);
        vm.prank(alice);
        lpm.modifyLiquidities(calls, _deadline);
        snapLastCall("PositionManager_mint_onSameTickLower");
    }

    function test_gas_mint_sameTickUpper() public {
        // Explicitly mint to range whos tickUpperis the same.
        LiquidityRange memory bob_mint = LiquidityRange({poolKey: key, tickLower: 60, tickUpper: range.tickUpper});
        vm.startPrank(bob);
        mint(bob_mint, 10_000 ether, address(bob), ZERO_BYTES);
        vm.stopPrank();
        // Mint to a diff range, diff user.
        Planner.Plan memory planner =
            Planner.init().add(Actions.MINT, abi.encode(range, 10_000 ether, address(alice), ZERO_BYTES));
        bytes memory calls = planner.finalize(range.poolKey);
        vm.prank(alice);
        lpm.modifyLiquidities(calls, _deadline);
        snapLastCall("PositionManager_mint_onSameTickUpper");
    }

    function test_gas_increaseLiquidity_erc20() public {
        mint(range, 10_000 ether, address(this), ZERO_BYTES);
        uint256 tokenId = lpm.nextTokenId() - 1;

        Planner.Plan memory planner =
            Planner.init().add(Actions.INCREASE, abi.encode(tokenId, 10_000 ether, ZERO_BYTES));

        bytes memory calls = planner.finalize(range.poolKey);
        lpm.modifyLiquidities(calls, _deadline);
        snapLastCall("PositionManager_increaseLiquidity_erc20");
    }

    function test_gas_autocompound_exactUnclaimedFees() public {
        // Alice and Bob provide liquidity on the range
        // Alice uses her exact fees to increase liquidity (compounding)

        uint256 liquidityAlice = 3_000e18;
        uint256 liquidityBob = 1_000e18;

        // alice provides liquidity
        vm.prank(alice);
        mint(range, liquidityAlice, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // bob provides liquidity
        vm.prank(bob);
        mint(range, liquidityBob, bob, ZERO_BYTES);

        // donate to create fees
        uint256 amountDonate = 0.2e18;
        donateRouter.donate(key, amountDonate, amountDonate, ZERO_BYTES);

        // alice uses her exact fees to increase liquidity
        uint256 tokensOwedAlice = amountDonate.mulDivDown(liquidityAlice, liquidityAlice + liquidityBob) - 1;

        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, range.poolKey.toId());
        uint256 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(range.tickLower),
            TickMath.getSqrtPriceAtTick(range.tickUpper),
            tokensOwedAlice,
            tokensOwedAlice
        );

        Planner.Plan memory planner =
            Planner.init().add(Actions.INCREASE, abi.encode(tokenIdAlice, liquidityDelta, ZERO_BYTES));

        bytes memory calls = planner.finalize(range.poolKey);
        vm.prank(alice);
        lpm.modifyLiquidities(calls, _deadline);
        snapLastCall("PositionManager_increase_autocompoundExactUnclaimedFees");
    }

    // Autocompounding but the excess fees are taken to the user
    function test_gas_autocompound_excessFeesCredit() public {
        // Alice and Bob provide liquidity on the range
        // Alice uses her fees to increase liquidity. Excess fees are accounted to alice
        uint256 liquidityAlice = 3_000e18;
        uint256 liquidityBob = 1_000e18;

        // alice provides liquidity
        vm.prank(alice);
        mint(range, liquidityAlice, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // bob provides liquidity
        vm.prank(bob);
        mint(range, liquidityBob, bob, ZERO_BYTES);

        // donate to create fees
        uint256 amountDonate = 20e18;
        donateRouter.donate(key, amountDonate, amountDonate, ZERO_BYTES);

        // alice will use half of her fees to increase liquidity
        uint256 halfTokensOwedAlice = (amountDonate.mulDivDown(liquidityAlice, liquidityAlice + liquidityBob) - 1) / 2;

        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, range.poolKey.toId());
        uint256 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(range.tickLower),
            TickMath.getSqrtPriceAtTick(range.tickUpper),
            halfTokensOwedAlice,
            halfTokensOwedAlice
        );

        Planner.Plan memory planner =
            Planner.init().add(Actions.INCREASE, abi.encode(tokenIdAlice, liquidityDelta, ZERO_BYTES));

        bytes memory calls = planner.finalize(range.poolKey);

        vm.prank(alice);
        lpm.modifyLiquidities(calls, _deadline);
        snapLastCall("PositionManager_increase_autocompoundExcessFeesCredit");
    }

    function test_gas_decreaseLiquidity() public {
        mint(range, 10_000 ether, address(this), ZERO_BYTES);
        uint256 tokenId = lpm.nextTokenId() - 1;

        Planner.Plan memory planner =
            Planner.init().add(Actions.DECREASE, abi.encode(tokenId, 10_000 ether, ZERO_BYTES));

        bytes memory calls = planner.finalize(range.poolKey);
        lpm.modifyLiquidities(calls, _deadline);
        snapLastCall("PositionManager_decreaseLiquidity");
    }

    function test_gas_multicall_initialize_mint() public {
        key = PoolKey({currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 10, hooks: IHooks(address(0))});

        // Use multicall to initialize a pool and mint liquidity
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(lpm.initializePool.selector, key, SQRT_PRICE_1_1, ZERO_BYTES);

        range = LiquidityRange({
            poolKey: key,
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing)
        });

        Planner.Plan memory planner = Planner.init();
        planner = planner.add(Actions.MINT, abi.encode(range, 100e18, address(this), ZERO_BYTES));
        bytes memory actions = planner.finalize(range.poolKey);

        calls[1] = abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector, actions, _deadline);

        IMulticall(lpm).multicall(calls);
        snapLastCall("PositionManager_multicall_initialize_mint");
    }

    function test_gas_collect() public {
        mint(range, 10_000 ether, address(this), ZERO_BYTES);
        uint256 tokenId = lpm.nextTokenId() - 1;

        // donate to create fee revenue
        donateRouter.donate(range.poolKey, 0.2e18, 0.2e18, ZERO_BYTES);

        // Collect by calling decrease with 0.
        Planner.Plan memory planner = Planner.init().add(Actions.DECREASE, abi.encode(tokenId, 0, ZERO_BYTES, false));

        bytes memory calls = planner.finalize(range.poolKey);
        lpm.modifyLiquidities(calls, _deadline);
        snapLastCall("PositionManager_collect");
    }

    // same-range gas tests
    function test_gas_sameRange_mint() public {
        mint(range, 10_000 ether, address(this), ZERO_BYTES);

        Planner.Plan memory planner =
            Planner.init().add(Actions.MINT, abi.encode(range, 10_001 ether, address(alice), ZERO_BYTES));
        bytes memory calls = planner.finalize(range.poolKey);
        vm.prank(alice);
        lpm.modifyLiquidities(calls, _deadline);
        snapLastCall("PositionManager_mint_sameRange");
    }

    function test_gas_sameRange_decrease() public {
        // two positions of the same range, one of them decreases the entirety of the liquidity
        vm.startPrank(alice);
        mint(range, 10_000 ether, address(this), ZERO_BYTES);
        vm.stopPrank();

        mint(range, 10_000 ether, address(this), ZERO_BYTES);
        uint256 tokenId = lpm.nextTokenId() - 1;

        Planner.Plan memory planner =
            Planner.init().add(Actions.DECREASE, abi.encode(tokenId, 10_000 ether, ZERO_BYTES, false));

        bytes memory calls = planner.finalize(range.poolKey);
        lpm.modifyLiquidities(calls, _deadline);
        snapLastCall("PositionManager_decrease_sameRange_allLiquidity");
    }

    function test_gas_sameRange_collect() public {
        // two positions of the same range, one of them collects all their fees
        vm.startPrank(alice);
        mint(range, 10_000 ether, address(this), ZERO_BYTES);
        vm.stopPrank();

        mint(range, 10_000 ether, address(this), ZERO_BYTES);
        uint256 tokenId = lpm.nextTokenId() - 1;

        // donate to create fee revenue
        donateRouter.donate(range.poolKey, 0.2e18, 0.2e18, ZERO_BYTES);

        Planner.Plan memory planner = Planner.init().add(Actions.DECREASE, abi.encode(tokenId, 0, ZERO_BYTES, false));

        bytes memory calls = planner.finalize(range.poolKey);
        lpm.modifyLiquidities(calls, _deadline);
        snapLastCall("PositionManager_collect_sameRange");
    }

    // TODO: ERC6909 Support.
    function test_gas_increaseLiquidity_erc6909() public {}
    function test_gas_decreaseLiquidity_erc6909() public {}

    function test_gas_burn() public {}
    function test_gas_burnEmpty() public {}

    // Native Token Gas Tests
    function test_gas_mint_native() public {
        uint256 liquidityToAdd = 10_000 ether;
        bytes memory calls = getMintEncoded(nativeRange, liquidityToAdd, address(this), ZERO_BYTES);

        (uint256 amount0,) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(nativeRange.tickLower),
            TickMath.getSqrtPriceAtTick(nativeRange.tickUpper),
            uint128(liquidityToAdd)
        );
        lpm.modifyLiquidities{value: amount0 + 1}(calls, _deadline);
        snapLastCall("PositionManager_mint_native");
    }

    function test_gas_mint_native_excess() public {
        uint256 liquidityToAdd = 10_000 ether;
        bytes memory calls = getMintEncoded(nativeRange, liquidityToAdd, address(this), ZERO_BYTES);

        (uint256 amount0,) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(nativeRange.tickLower),
            TickMath.getSqrtPriceAtTick(nativeRange.tickUpper),
            uint128(liquidityToAdd)
        );
        // overpay on the native token
        lpm.modifyLiquidities{value: amount0 * 2}(calls, _deadline);
        snapLastCall("PositionManager_mint_nativeWithSweep");
    }

    function test_gas_increase_native() public {
        uint256 tokenId = lpm.nextTokenId();
        mintWithNative(SQRT_PRICE_1_1, nativeRange, 10_000 ether, address(this), ZERO_BYTES);

        uint256 liquidityToAdd = 10_000 ether;
        bytes memory calls = getIncreaseEncoded(tokenId, liquidityToAdd, ZERO_BYTES);
        (uint256 amount0,) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(nativeRange.tickLower),
            TickMath.getSqrtPriceAtTick(nativeRange.tickUpper),
            uint128(liquidityToAdd)
        );
        lpm.modifyLiquidities{value: amount0 + 1}(calls, _deadline);
        snapLastCall("PositionManager_increaseLiquidity_native");
    }

    function test_gas_decrease_native() public {
        uint256 tokenId = lpm.nextTokenId();
        mintWithNative(SQRT_PRICE_1_1, nativeRange, 10_000 ether, address(this), ZERO_BYTES);

        uint256 liquidityToRemove = 10_000 ether;
        bytes memory calls = getDecreaseEncoded(tokenId, liquidityToRemove, ZERO_BYTES);
        lpm.modifyLiquidities(calls, _deadline);
        snapLastCall("PositionManager_decreaseLiquidity_native");
    }

    function test_gas_collect_native() public {
        uint256 tokenId = lpm.nextTokenId();
        mintWithNative(SQRT_PRICE_1_1, nativeRange, 10_000 ether, address(this), ZERO_BYTES);

        // donate to create fee revenue
        donateRouter.donate{value: 0.2e18}(nativeRange.poolKey, 0.2e18, 0.2e18, ZERO_BYTES);

        bytes memory calls = getCollectEncoded(tokenId, ZERO_BYTES);
        lpm.modifyLiquidities(calls, _deadline);
        snapLastCall("PositionManager_collect_native");
    }
}
