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
import {LiquidityAmounts} from "../../contracts/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import {INonfungiblePositionManager, Actions} from "../../contracts/interfaces/INonfungiblePositionManager.sol";
import {NonfungiblePositionManager} from "../../contracts/NonfungiblePositionManager.sol";
import {LiquidityRange, LiquidityRangeId, LiquidityRangeIdLibrary} from "../../contracts/types/LiquidityRange.sol";

import {LiquidityOperations} from "../shared/LiquidityOperations.sol";
import {Planner} from "../utils/Planner.sol";

contract GasTest is Test, Deployers, GasSnapshot, LiquidityOperations {
    using FixedPointMathLib for uint256;
    using CurrencyLibrary for Currency;
    using LiquidityRangeIdLibrary for LiquidityRange;
    using PoolIdLibrary for PoolKey;
    using Planner for Planner.Plan;

    PoolId poolId;
    address alice = makeAddr("ALICE");
    address bob = makeAddr("BOB");

    uint256 constant STARTING_USER_BALANCE = 10_000_000 ether;

    // expresses the fee as a wad (i.e. 3000 = 0.003e18 = 0.30%)
    uint256 FEE_WAD;

    LiquidityRange range;

    function setUp() public {
        Deployers.deployFreshManagerAndRouters();
        Deployers.deployMintAndApprove2Currencies();

        (key, poolId) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1, ZERO_BYTES);
        FEE_WAD = uint256(key.fee).mulDivDown(FixedPointMathLib.WAD, 1_000_000);

        lpm = new NonfungiblePositionManager(manager);
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
        range = LiquidityRange({poolKey: key, tickLower: -300, tickUpper: 300});
    }

    function test_gas_mint() public {
        Planner.Plan memory planner = Planner.init().add(
            Actions.MINT, abi.encode(range, 10_000 ether, block.timestamp + 1, address(this), ZERO_BYTES)
        );
        planner = planner.finalize(range);
        lpm.modifyLiquidities(planner.zip());
        snapLastCall("mint");
    }

    function test_gas_increaseLiquidity_erc20() public {
        _mint(range, 10_000 ether, block.timestamp + 1, address(this), ZERO_BYTES);
        uint256 tokenId = lpm.lastTokenId();

        Planner.Plan memory planner =
            Planner.init().add(Actions.INCREASE, abi.encode(tokenId, 10_000 ether, ZERO_BYTES));

        planner = planner.finalize(range);

        lpm.modifyLiquidities(abi.encode(planner.actions, planner.params));
        snapLastCall("increaseLiquidity_erc20");
    }

    function test_gas_increaseLiquidity_erc6909() public {
        _mint(range, 10_000 ether, block.timestamp + 1, address(this), ZERO_BYTES);
        uint256 tokenId = lpm.lastTokenId();

        Planner.Plan memory planner =
            Planner.init().add(Actions.INCREASE, abi.encode(tokenId, 10_000 ether, ZERO_BYTES));

        planner = planner.finalize(range);

        lpm.modifyLiquidities(abi.encode(planner.actions, planner.params));
        snapLastCall("increaseLiquidity_erc6909");
    }

    function test_gas_autocompound_exactUnclaimedFees() public {
        // Alice and Bob provide liquidity on the range
        // Alice uses her exact fees to increase liquidity (compounding)

        uint256 liquidityAlice = 3_000e18;
        uint256 liquidityBob = 1_000e18;

        // alice provides liquidity
        vm.prank(alice);
        _mint(range, liquidityAlice, block.timestamp + 1, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.lastTokenId();

        // bob provides liquidity
        vm.prank(bob);
        _mint(range, liquidityBob, block.timestamp + 1, bob, ZERO_BYTES);

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

        planner = planner.finalize(range);

        vm.prank(alice);
        lpm.modifyLiquidities(abi.encode(planner.actions, planner.params));
        snapLastCall("autocompound_exactUnclaimedFees");
    }

    function test_gas_autocompound_exactUnclaimedFees_exactCustodiedFees() public {
        // Alice and Bob provide liquidity on the range
        // Alice uses her fees to increase liquidity. Both unclaimed fees and cached fees are used to exactly increase the liquidity
        uint256 liquidityAlice = 3_000e18;
        uint256 liquidityBob = 1_000e18;

        // alice provides liquidity
        vm.prank(alice);
        _mint(range, liquidityAlice, block.timestamp + 1, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.lastTokenId();

        // bob provides liquidity
        vm.prank(bob);
        _mint(range, liquidityBob, block.timestamp + 1, bob, ZERO_BYTES);
        uint256 tokenIdBob = lpm.lastTokenId();

        // donate to create fees
        uint256 amountDonate = 20e18;
        donateRouter.donate(key, amountDonate, amountDonate, ZERO_BYTES);
        uint256 tokensOwedAlice = amountDonate.mulDivDown(liquidityAlice, liquidityAlice + liquidityBob) - 1;

        // bob collects fees so some of alice's fees are now cached

        Planner.Plan memory planner = Planner.init().add(Actions.DECREASE, abi.encode(tokenIdBob, 0, ZERO_BYTES));

        planner = planner.finalize(range);

        vm.prank(bob);
        lpm.modifyLiquidities(abi.encode(planner.actions, planner.params));

        // donate to create more fees
        donateRouter.donate(key, amountDonate, amountDonate, ZERO_BYTES);

        tokensOwedAlice = tokensOwedAlice + amountDonate.mulDivDown(liquidityAlice, liquidityAlice + liquidityBob) - 1;

        // alice will use ALL of her fees to increase liquidity
        {
            (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, range.poolKey.toId());
            uint256 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(range.tickLower),
                TickMath.getSqrtPriceAtTick(range.tickUpper),
                tokensOwedAlice,
                tokensOwedAlice
            );

            planner = Planner.init().add(Actions.INCREASE, abi.encode(tokenIdAlice, liquidityDelta, ZERO_BYTES));

            planner = planner.finalize(range);

            vm.prank(alice);
            lpm.modifyLiquidities(abi.encode(planner.actions, planner.params));
            snapLastCall("autocompound_exactUnclaimedFees_exactCustodiedFees");
        }
    }

    // autocompounding but the excess fees are credited to tokensOwed
    function test_gas_autocompound_excessFeesCredit() public {
        // Alice and Bob provide liquidity on the range
        // Alice uses her fees to increase liquidity. Excess fees are accounted to alice
        uint256 liquidityAlice = 3_000e18;
        uint256 liquidityBob = 1_000e18;

        // alice provides liquidity
        vm.prank(alice);
        _mint(range, liquidityAlice, block.timestamp + 1, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.lastTokenId();

        // bob provides liquidity
        vm.prank(bob);
        _mint(range, liquidityBob, block.timestamp + 1, bob, ZERO_BYTES);

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

        planner = planner.finalize(range);

        vm.prank(alice);
        lpm.modifyLiquidities(abi.encode(planner.actions, planner.params));
        snapLastCall("autocompound_excessFeesCredit");
    }

    function test_gas_decreaseLiquidity_erc20() public {
        _mint(range, 10_000 ether, block.timestamp + 1, address(this), ZERO_BYTES);
        uint256 tokenId = lpm.lastTokenId();

        Planner.Plan memory planner =
            Planner.init().add(Actions.DECREASE, abi.encode(tokenId, 10_000 ether, ZERO_BYTES));

        planner = planner.finalize(range);

        lpm.modifyLiquidities(abi.encode(planner.actions, planner.params));
        snapLastCall("decreaseLiquidity_erc20");
    }

    function test_gas_decreaseLiquidity_erc6909() public {
        _mint(range, 10_000 ether, block.timestamp + 1, address(this), ZERO_BYTES);
        uint256 tokenId = lpm.lastTokenId();

        Planner.Plan memory planner =
            Planner.init().add(Actions.DECREASE, abi.encode(tokenId, 10_000 ether, ZERO_BYTES));

        planner = planner.finalize(range);

        lpm.modifyLiquidities(abi.encode(planner.actions, planner.params));
        snapLastCall("decreaseLiquidity_erc6909");
    }

    function test_gas_burn() public {}
    function test_gas_burnEmpty() public {}
    function test_gas_collect() public {}
}
