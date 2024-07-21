// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FeeMath} from "../shared/FeeMath.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import {IPositionManager, Actions} from "../../src/interfaces/IPositionManager.sol";
import {PositionManager} from "../../src/PositionManager.sol";
import {PoolPosition} from "../../src/libraries/PoolPosition.sol";
import {IMulticall} from "../../src/interfaces/IMulticall.sol";

import {LiquidityOperations} from "../shared/LiquidityOperations.sol";
import {Planner} from "../utils/Planner.sol";

contract GasTest is Test, Deployers, GasSnapshot, LiquidityOperations {
    using FixedPointMathLib for uint256;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using Planner for Planner.Plan;
    using FeeMath for IPositionManager;

    PoolId poolId;
    address alice;
    uint256 alicePK;
    address bob;
    uint256 bobPK;

    uint256 constant STARTING_USER_BALANCE = 10_000_000 ether;

    // expresses the fee as a wad (i.e. 3000 = 0.003e18 = 0.30%)
    uint256 FEE_WAD;

    PoolPosition poolPos;

    function setUp() public {
        (alice, alicePK) = makeAddrAndKey("ALICE");
        (bob, bobPK) = makeAddrAndKey("BOB");

        Deployers.deployFreshManagerAndRouters();
        Deployers.deployMintAndApprove2Currencies();

        (key, poolId) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1, ZERO_BYTES);
        FEE_WAD = uint256(key.fee).mulDivDown(FixedPointMathLib.WAD, 1_000_000);

        lpm = new PositionManager(manager);
        IERC20(Currency.unwrap(currency0)).approve(address(lpm), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(lpm), type(uint256).max);

        // Give tokens to Alice and Bob, with approvals
        IERC20(Currency.unwrap(currency0)).transfer(alice, STARTING_USER_BALANCE);
        IERC20(Currency.unwrap(currency1)).transfer(alice, STARTING_USER_BALANCE);
        IERC20(Currency.unwrap(currency0)).transfer(bob, STARTING_USER_BALANCE);
        IERC20(Currency.unwrap(currency1)).transfer(bob, STARTING_USER_BALANCE);
        vm.startPrank(alice);
        IERC20(Currency.unwrap(currency0)).approve(address(lpm), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(lpm), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob);
        IERC20(Currency.unwrap(currency0)).approve(address(lpm), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(lpm), type(uint256).max);
        vm.stopPrank();

        // mint some ERC6909 tokens
        claimsRouter.deposit(currency0, address(this), 100_000_000 ether);
        claimsRouter.deposit(currency1, address(this), 100_000_000 ether);
        manager.setOperator(address(lpm), true);

        // define a reusable range
        poolPos = PoolPosition({poolKey: key, tickLower: -300, tickUpper: 300});
    }

    function test_gas_mint() public {
        Planner.Plan memory planner =
            Planner.init().add(Actions.MINT, abi.encode(poolPos, 10_000 ether, address(this), ZERO_BYTES));
        bytes memory calls = planner.finalize(poolPos.poolKey);
        lpm.modifyLiquidities(calls, _deadline);
        snapLastCall("PositionManager_mint");
    }

    function test_gas_mint_differentRanges() public {
        // Explicitly mint to a new range on the same pool.
        PoolPosition memory bob_mint = PoolPosition({poolKey: key, tickLower: 0, tickUpper: 60});
        vm.startPrank(bob);
        mint(bob_mint, 10_000 ether, address(bob), ZERO_BYTES);
        vm.stopPrank();
        // Mint to a diff poolPos, diff user.
        Planner.Plan memory planner =
            Planner.init().add(Actions.MINT, abi.encode(poolPos, 10_000 ether, address(alice), ZERO_BYTES));
        bytes memory calls = planner.finalize(poolPos.poolKey);
        vm.prank(alice);
        lpm.modifyLiquidities(calls, _deadline);
        snapLastCall("PositionManager_mint_warmedPool_differentRange");
    }

    function test_gas_mint_sameTickLower() public {
        // Explicitly mint to range whos tickLower is the same.
        PoolPosition memory bob_mint = PoolPosition({poolKey: key, tickLower: -300, tickUpper: -60});
        vm.startPrank(bob);
        mint(bob_mint, 10_000 ether, address(bob), ZERO_BYTES);
        vm.stopPrank();
        // Mint to a diff poolPos, diff user.
        Planner.Plan memory planner =
            Planner.init().add(Actions.MINT, abi.encode(poolPos, 10_000 ether, address(alice), ZERO_BYTES));
        bytes memory calls = planner.finalize(poolPos.poolKey);
        vm.prank(alice);
        lpm.modifyLiquidities(calls, _deadline);
        snapLastCall("PositionManager_mint_onSameTickLower");
    }

    function test_gas_mint_sameTickUpper() public {
        // Explicitly mint to range whos tickUpperis the same.
        PoolPosition memory bob_mint = PoolPosition({poolKey: key, tickLower: 60, tickUpper: 300});
        vm.startPrank(bob);
        mint(bob_mint, 10_000 ether, address(bob), ZERO_BYTES);
        vm.stopPrank();
        // Mint to a diff poolPos, diff user.
        Planner.Plan memory planner =
            Planner.init().add(Actions.MINT, abi.encode(poolPos, 10_000 ether, address(alice), ZERO_BYTES));
        bytes memory calls = planner.finalize(poolPos.poolKey);
        vm.prank(alice);
        lpm.modifyLiquidities(calls, _deadline);
        snapLastCall("PositionManager_mint_onSameTickUpper");
    }

    function test_gas_increaseLiquidity_erc20() public {
        mint(poolPos, 10_000 ether, address(this), ZERO_BYTES);
        uint256 tokenId = lpm.nextTokenId() - 1;

        Planner.Plan memory planner =
            Planner.init().add(Actions.INCREASE, abi.encode(tokenId, poolPos, 10_000 ether, ZERO_BYTES));

        bytes memory calls = planner.finalize(poolPos.poolKey);
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
        mint(poolPos, liquidityAlice, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // bob provides liquidity
        vm.prank(bob);
        mint(poolPos, liquidityBob, bob, ZERO_BYTES);

        // donate to create fees
        uint256 amountDonate = 0.2e18;
        donateRouter.donate(key, amountDonate, amountDonate, ZERO_BYTES);

        // alice uses her exact fees to increase liquidity
        uint256 tokensOwedAlice = amountDonate.mulDivDown(liquidityAlice, liquidityAlice + liquidityBob) - 1;

        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, poolPos.poolKey.toId());
        uint256 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(poolPos.tickLower),
            TickMath.getSqrtPriceAtTick(poolPos.tickUpper),
            tokensOwedAlice,
            tokensOwedAlice
        );

        Planner.Plan memory planner =
            Planner.init().add(Actions.INCREASE, abi.encode(tokenIdAlice, poolPos, liquidityDelta, ZERO_BYTES));

        bytes memory calls = planner.finalize(poolPos.poolKey);
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
        mint(poolPos, liquidityAlice, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // bob provides liquidity
        vm.prank(bob);
        mint(poolPos, liquidityBob, bob, ZERO_BYTES);

        // donate to create fees
        uint256 amountDonate = 20e18;
        donateRouter.donate(key, amountDonate, amountDonate, ZERO_BYTES);

        // alice will use half of her fees to increase liquidity
        uint256 halfTokensOwedAlice = (amountDonate.mulDivDown(liquidityAlice, liquidityAlice + liquidityBob) - 1) / 2;

        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, poolPos.poolKey.toId());
        uint256 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(poolPos.tickLower),
            TickMath.getSqrtPriceAtTick(poolPos.tickUpper),
            halfTokensOwedAlice,
            halfTokensOwedAlice
        );

        Planner.Plan memory planner =
            Planner.init().add(Actions.INCREASE, abi.encode(tokenIdAlice, poolPos, liquidityDelta, ZERO_BYTES));

        bytes memory calls = planner.finalize(poolPos.poolKey);

        vm.prank(alice);
        lpm.modifyLiquidities(calls, _deadline);
        snapLastCall("PositionManager_increase_autocompoundExcessFeesCredit");
    }

    function test_gas_decreaseLiquidity() public {
        mint(poolPos, 10_000 ether, address(this), ZERO_BYTES);
        uint256 tokenId = lpm.nextTokenId() - 1;

        Planner.Plan memory planner =
            Planner.init().add(Actions.DECREASE, abi.encode(tokenId, poolPos, 10_000 ether, ZERO_BYTES));

        bytes memory calls = planner.finalize(poolPos.poolKey);
        lpm.modifyLiquidities(calls, _deadline);
        snapLastCall("PositionManager_decreaseLiquidity");
    }

    function test_gas_multicall_initialize_mint() public {
        key = PoolKey({currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 10, hooks: IHooks(address(0))});

        // Use multicall to initialize a pool and mint liquidity
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(lpm.initializePool.selector, key, SQRT_PRICE_1_1, ZERO_BYTES);

        poolPos = PoolPosition({
            poolKey: key,
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing)
        });

        Planner.Plan memory planner = Planner.init();
        planner = planner.add(Actions.MINT, abi.encode(poolPos, 100e18, address(this), ZERO_BYTES));
        bytes memory actions = planner.finalize(poolPos.poolKey);

        calls[1] = abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector, actions, _deadline);

        IMulticall(lpm).multicall(calls);
        snapLastCall("PositionManager_multicall_initialize_mint");
    }

    function test_gas_collect() public {
        mint(poolPos, 10_000 ether, address(this), ZERO_BYTES);
        uint256 tokenId = lpm.nextTokenId() - 1;

        // donate to create fee revenue
        donateRouter.donate(poolPos.poolKey, 0.2e18, 0.2e18, ZERO_BYTES);

        // Collect by calling decrease with 0.
        Planner.Plan memory planner =
            Planner.init().add(Actions.DECREASE, abi.encode(tokenId, poolPos, 0, ZERO_BYTES, false));

        bytes memory calls = planner.finalize(poolPos.poolKey);
        lpm.modifyLiquidities(calls, _deadline);
        snapLastCall("PositionManager_collect");
    }

    // same-range gas tests
    function test_gas_sameRange_mint() public {
        mint(poolPos, 10_000 ether, address(this), ZERO_BYTES);

        Planner.Plan memory planner =
            Planner.init().add(Actions.MINT, abi.encode(poolPos, 10_001 ether, address(alice), ZERO_BYTES));
        bytes memory calls = planner.finalize(poolPos.poolKey);
        vm.prank(alice);
        lpm.modifyLiquidities(calls, _deadline);
        snapLastCall("PositionManager_mint_sameRange");
    }

    function test_gas_sameRange_decrease() public {
        // two positions of the same poolPos, one of them decreases the entirety of the liquidity
        vm.startPrank(alice);
        mint(poolPos, 10_000 ether, address(this), ZERO_BYTES);
        vm.stopPrank();

        mint(poolPos, 10_000 ether, address(this), ZERO_BYTES);
        uint256 tokenId = lpm.nextTokenId() - 1;

        Planner.Plan memory planner =
            Planner.init().add(Actions.DECREASE, abi.encode(tokenId, poolPos, 10_000 ether, ZERO_BYTES, false));

        bytes memory calls = planner.finalize(poolPos.poolKey);
        lpm.modifyLiquidities(calls, _deadline);
        snapLastCall("PositionManager_decrease_sameRange_allLiquidity");
    }

    function test_gas_sameRange_collect() public {
        // two positions of the same poolPos, one of them collects all their fees
        vm.startPrank(alice);
        mint(poolPos, 10_000 ether, address(this), ZERO_BYTES);
        vm.stopPrank();

        mint(poolPos, 10_000 ether, address(this), ZERO_BYTES);
        uint256 tokenId = lpm.nextTokenId() - 1;

        // donate to create fee revenue
        donateRouter.donate(poolPos.poolKey, 0.2e18, 0.2e18, ZERO_BYTES);

        Planner.Plan memory planner =
            Planner.init().add(Actions.DECREASE, abi.encode(tokenId, poolPos, 0, ZERO_BYTES, false));

        bytes memory calls = planner.finalize(poolPos.poolKey);
        lpm.modifyLiquidities(calls, _deadline);
        snapLastCall("PositionManager_collect_sameRange");
    }

    // TODO: ERC6909 Support.
    function test_gas_increaseLiquidity_erc6909() public {}
    function test_gas_decreaseLiquidity_erc6909() public {}

    function test_gas_burn() public {}
    function test_gas_burnEmpty() public {}
}
