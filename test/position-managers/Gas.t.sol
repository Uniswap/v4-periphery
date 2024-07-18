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

import {INonfungiblePositionManager, Actions} from "../../src/interfaces/INonfungiblePositionManager.sol";
import {NonfungiblePositionManager} from "../../src/NonfungiblePositionManager.sol";
import {LiquidityRange, LiquidityRangeId, LiquidityRangeIdLibrary} from "../../src/types/LiquidityRange.sol";

import {LiquidityOperations} from "../shared/LiquidityOperations.sol";
import {Planner} from "../utils/Planner.sol";

contract GasTest is Test, Deployers, GasSnapshot, LiquidityOperations {
    using FixedPointMathLib for uint256;
    using CurrencyLibrary for Currency;
    using LiquidityRangeIdLibrary for LiquidityRange;
    using PoolIdLibrary for PoolKey;
    using Planner for Planner.Plan;
    using FeeMath for INonfungiblePositionManager;

    PoolId poolId;
    address alice;
    uint256 alicePK;
    address bob;
    uint256 bobPK;

    uint256 constant STARTING_USER_BALANCE = 10_000_000 ether;

    // expresses the fee as a wad (i.e. 3000 = 0.003e18 = 0.30%)
    uint256 FEE_WAD;

    LiquidityRange range;

    function setUp() public {
        (alice, alicePK) = makeAddrAndKey("ALICE");
        (bob, bobPK) = makeAddrAndKey("BOB");

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
        Planner.Plan memory planner =
            Planner.init().add(Actions.MINT, abi.encode(range, 10_000 ether, address(this), ZERO_BYTES));
        planner = planner.finalize(range.poolKey);
        bytes memory actions = planner.zip();
        lpm.modifyLiquidities(actions, _deadline);
        snapLastCall("mint");
    }

    function test_gas_mint_differentRanges() public {
        // Explicitly mint to a new range on the same pool.
        LiquidityRange memory bob_mint = LiquidityRange({poolKey: key, tickLower: 0, tickUpper: 60});
        vm.startPrank(bob);
        _mint(bob_mint, 10_000 ether, address(bob), ZERO_BYTES);
        vm.stopPrank();
        // Mint to a diff range, diff user.
        Planner.Plan memory planner =
            Planner.init().add(Actions.MINT, abi.encode(range, 10_000 ether, address(alice), ZERO_BYTES));
        planner = planner.finalize(range.poolKey);
        vm.prank(alice);
        bytes memory actions = planner.zip();
        lpm.modifyLiquidities(actions, _deadline);
        snapLastCall("mint_differentRanges");
    }

    function test_gas_mint_sameTickLower() public {
        // Explicitly mint to range whos tickLower is the same.
        LiquidityRange memory bob_mint = LiquidityRange({poolKey: key, tickLower: -300, tickUpper: -60});
        vm.startPrank(bob);
        _mint(bob_mint, 10_000 ether, address(bob), ZERO_BYTES);
        vm.stopPrank();
        // Mint to a diff range, diff user.
        Planner.Plan memory planner =
            Planner.init().add(Actions.MINT, abi.encode(range, 10_000 ether, address(alice), ZERO_BYTES));
        planner = planner.finalize(range.poolKey);
        vm.prank(alice);
        bytes memory actions = planner.zip();
        lpm.modifyLiquidities(actions, _deadline);
        snapLastCall("mint_same_tickLower");
    }

    function test_gas_mint_sameTickUpper() public {
        // Explicitly mint to range whos tickUpperis the same.
        LiquidityRange memory bob_mint = LiquidityRange({poolKey: key, tickLower: 60, tickUpper: 300});
        vm.startPrank(bob);
        _mint(bob_mint, 10_000 ether, address(bob), ZERO_BYTES);
        vm.stopPrank();
        // Mint to a diff range, diff user.
        Planner.Plan memory planner =
            Planner.init().add(Actions.MINT, abi.encode(range, 10_000 ether, address(alice), ZERO_BYTES));
        planner = planner.finalize(range.poolKey);
        vm.prank(alice);
        bytes memory actions = planner.zip();
        lpm.modifyLiquidities(actions, _deadline);
        snapLastCall("mint_same_tickUpper");
    }

    function test_gas_increaseLiquidity_erc20() public {
        _mint(range, 10_000 ether, address(this), ZERO_BYTES);
        uint256 tokenId = lpm.nextTokenId() - 1;

        Planner.Plan memory planner =
            Planner.init().add(Actions.INCREASE, abi.encode(tokenId, 10_000 ether, ZERO_BYTES));

        planner = planner.finalize(range.poolKey);

        bytes memory actions = planner.zip();
        lpm.modifyLiquidities(actions, _deadline);
        snapLastCall("increaseLiquidity_erc20");
    }

    function test_gas_increaseLiquidity_erc6909() public {
        _mint(range, 10_000 ether, address(this), ZERO_BYTES);
        uint256 tokenId = lpm.nextTokenId() - 1;

        Planner.Plan memory planner =
            Planner.init().add(Actions.INCREASE, abi.encode(tokenId, 10_000 ether, ZERO_BYTES));

        planner = planner.finalize(range.poolKey);

        bytes memory actions = planner.zip();
        lpm.modifyLiquidities(actions, _deadline);
        snapLastCall("increaseLiquidity_erc6909");
    }

    function test_gas_autocompound_exactUnclaimedFees() public {
        // Alice and Bob provide liquidity on the range
        // Alice uses her exact fees to increase liquidity (compounding)

        uint256 liquidityAlice = 3_000e18;
        uint256 liquidityBob = 1_000e18;

        // alice provides liquidity
        vm.prank(alice);
        _mint(range, liquidityAlice, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // bob provides liquidity
        vm.prank(bob);
        _mint(range, liquidityBob, bob, ZERO_BYTES);

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

        planner = planner.finalize(range.poolKey);

        vm.prank(alice);
        bytes memory actions = planner.zip();
        lpm.modifyLiquidities(actions, _deadline);
        snapLastCall("autocompound_exactUnclaimedFees");
    }

    function test_gas_autocompound_exactUnclaimedFees_exactCustodiedFees() public {
        // Alice and Bob provide liquidity on the range
        // Alice uses her fees to increase liquidity. Both unclaimed fees and cached fees are used to exactly increase the liquidity
        uint256 liquidityAlice = 3_000e18;
        uint256 liquidityBob = 1_000e18;

        // alice provides liquidity
        vm.prank(alice);
        _mint(range, liquidityAlice, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // bob provides liquidity
        vm.prank(bob);
        _mint(range, liquidityBob, bob, ZERO_BYTES);
        uint256 tokenIdBob = lpm.nextTokenId() - 1;

        // donate to create fees
        uint256 amountDonate = 20e18;
        donateRouter.donate(key, amountDonate, amountDonate, ZERO_BYTES);
        uint256 tokensOwedAlice = amountDonate.mulDivDown(liquidityAlice, liquidityAlice + liquidityBob) - 1;

        // bob collects fees so some of alice's fees are now cached

        Planner.Plan memory planner = Planner.init().add(Actions.DECREASE, abi.encode(tokenIdBob, 0, ZERO_BYTES));

        planner = planner.finalize(range.poolKey);

        vm.prank(bob);
        bytes memory actions = planner.zip();
        lpm.modifyLiquidities(actions, _deadline);

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

            planner = planner.finalize(range.poolKey);

            vm.prank(alice);
            actions = planner.zip();
            lpm.modifyLiquidities(actions, _deadline);
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
        _mint(range, liquidityAlice, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // bob provides liquidity
        vm.prank(bob);
        _mint(range, liquidityBob, bob, ZERO_BYTES);

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

        planner = planner.finalize(range.poolKey);

        vm.prank(alice);
        bytes memory actions = planner.zip();
        lpm.modifyLiquidities(actions, _deadline);
        snapLastCall("autocompound_excessFeesCredit");
    }

    function test_gas_decreaseLiquidity_erc20() public {
        _mint(range, 10_000 ether, address(this), ZERO_BYTES);
        uint256 tokenId = lpm.nextTokenId() - 1;

        Planner.Plan memory planner =
            Planner.init().add(Actions.DECREASE, abi.encode(tokenId, 10_000 ether, ZERO_BYTES));

        planner = planner.finalize(range.poolKey);

        bytes memory actions = planner.zip();
        lpm.modifyLiquidities(actions, _deadline);
        snapLastCall("decreaseLiquidity_erc20");
    }

    function test_gas_decreaseLiquidity_erc6909() public {
        _mint(range, 10_000 ether, address(this), ZERO_BYTES);
        uint256 tokenId = lpm.nextTokenId() - 1;

        Planner.Plan memory planner =
            Planner.init().add(Actions.DECREASE, abi.encode(tokenId, 10_000 ether, ZERO_BYTES));

        planner = planner.finalize(range.poolKey);

        bytes memory actions = planner.zip();
        lpm.modifyLiquidities(actions, _deadline);
        snapLastCall("decreaseLiquidity_erc6909");
    }

    function test_gas_burn() public {}
    function test_gas_burnEmpty() public {}
    function test_gas_collect() public {}

    function test_gas_multicall_initialize_mint() public {
        key = PoolKey({currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 10, hooks: IHooks(address(0))});

        // Use multicall to initialize a pool and mint liquidity
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(
            NonfungiblePositionManager(lpm).initializePool.selector, key, SQRT_PRICE_1_1, ZERO_BYTES
        );

        range = LiquidityRange({
            poolKey: key,
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing)
        });

        Planner.Plan memory planner = Planner.init();
        planner = planner.add(Actions.MINT, abi.encode(range, 100e18, address(this), ZERO_BYTES));
        planner = planner.finalize(range.poolKey);

        calls[1] = abi.encodeWithSelector(NonfungiblePositionManager(lpm).modifyLiquidities.selector, planner.zip());

        lpm.multicall(calls);
        snapLastCall("multicall_initialize_mint");
    }

    function test_gas_permit() public {
        // alice permits for the first time
        uint256 liquidityAlice = 1e18;
        vm.prank(alice);
        _mint(range, liquidityAlice, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // alice gives operator permission to bob
        uint256 nonce = 1;
        bytes32 digest = lpm.getDigest(bob, tokenIdAlice, nonce, block.timestamp + 1);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);

        vm.prank(alice);
        lpm.permit(bob, tokenIdAlice, block.timestamp + 1, nonce, v, r, s);
        snapLastCall("permit");
    }

    function test_gas_permit_secondPosition() public {
        // alice permits for her two tokens, benchmark the 2nd permit
        uint256 liquidityAlice = 1e18;
        vm.prank(alice);
        _mint(range, liquidityAlice, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // alice gives operator permission to bob
        uint256 nonce = 1;
        bytes32 digest = lpm.getDigest(bob, tokenIdAlice, nonce, block.timestamp + 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);

        vm.prank(alice);
        lpm.permit(bob, tokenIdAlice, block.timestamp + 1, nonce, v, r, s);

        // alice creates another position
        vm.prank(alice);
        _mint(range, liquidityAlice, alice, ZERO_BYTES);
        tokenIdAlice = lpm.nextTokenId() - 1;

        // alice gives operator permission to bob
        nonce = 2;
        digest = lpm.getDigest(bob, tokenIdAlice, nonce, block.timestamp + 1);
        (v, r, s) = vm.sign(alicePK, digest);

        vm.prank(alice);
        lpm.permit(bob, tokenIdAlice, block.timestamp + 1, nonce, v, r, s);
        snapLastCall("permit_secondPosition");
    }

    function test_gas_permit_twice() public {
        // alice permits the same token, twice
        address charlie = makeAddr("CHARLIE");

        uint256 liquidityAlice = 1e18;
        vm.prank(alice);
        _mint(range, liquidityAlice, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // alice gives operator permission to bob
        uint256 nonce = 1;
        bytes32 digest = lpm.getDigest(bob, tokenIdAlice, nonce, block.timestamp + 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);

        vm.prank(alice);
        lpm.permit(bob, tokenIdAlice, block.timestamp + 1, nonce, v, r, s);

        // alice gives operator permission to charlie
        nonce = 2;
        digest = lpm.getDigest(charlie, tokenIdAlice, nonce, block.timestamp + 1);
        (v, r, s) = vm.sign(alicePK, digest);

        vm.prank(alice);
        lpm.permit(charlie, tokenIdAlice, block.timestamp + 1, nonce, v, r, s);
        snapLastCall("permit_twice");
    }

    function test_gas_collect_erc20() public {
        _mint(range, 10_000 ether, address(this), ZERO_BYTES);
        uint256 tokenId = lpm.nextTokenId() - 1;

        // donate to create fee revenue
        donateRouter.donate(range.poolKey, 0.2e18, 0.2e18, ZERO_BYTES);

        // Collect by calling decrease with 0.
        Planner.Plan memory planner = Planner.init().add(Actions.DECREASE, abi.encode(tokenId, 0, ZERO_BYTES, false));

        planner = planner.finalize(range.poolKey);
        bytes memory actions = planner.zip();
        lpm.modifyLiquidities(actions, _deadline);
        snapLastCall("collect_erc20");
    }

    // same-range gas tests
    function test_gas_sameRange_mint() public {
        _mint(range, 10_000 ether, address(this), ZERO_BYTES);

        Planner.Plan memory planner =
            Planner.init().add(Actions.MINT, abi.encode(range, 10_001 ether, address(alice), ZERO_BYTES));
        planner = planner.finalize(range.poolKey);
        vm.prank(alice);
        bytes memory actions = planner.zip();
        lpm.modifyLiquidities(actions, _deadline);
        snapLastCall("sameRange_mint");
    }

    function test_gas_sameRange_decrease() public {
        // two positions of the same range, one of them decreases the entirety of the liquidity
        vm.startPrank(alice);
        _mint(range, 10_000 ether, address(this), ZERO_BYTES);
        vm.stopPrank();

        _mint(range, 10_000 ether, address(this), ZERO_BYTES);
        uint256 tokenId = lpm.nextTokenId() - 1;

        Planner.Plan memory planner =
            Planner.init().add(Actions.DECREASE, abi.encode(tokenId, 10_000 ether, ZERO_BYTES, false));

        planner = planner.finalize(range.poolKey);

        bytes memory actions = planner.zip();
        lpm.modifyLiquidities(actions, _deadline);
        snapLastCall("sameRange_decreaseAllLiquidity");
    }

    function test_gas_sameRange_collect() public {
        // two positions of the same range, one of them collects all their fees
        vm.startPrank(alice);
        _mint(range, 10_000 ether, address(this), ZERO_BYTES);
        vm.stopPrank();

        _mint(range, 10_000 ether, address(this), ZERO_BYTES);
        uint256 tokenId = lpm.nextTokenId() - 1;

        // donate to create fee revenue
        donateRouter.donate(range.poolKey, 0.2e18, 0.2e18, ZERO_BYTES);

        Planner.Plan memory planner = Planner.init().add(Actions.DECREASE, abi.encode(tokenId, 0, ZERO_BYTES, false));

        planner = planner.finalize(range.poolKey);

        bytes memory actions = planner.zip();
        lpm.modifyLiquidities(actions, _deadline);
        snapLastCall("sameRange_collect");
    }
}
