// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {IMulticall_v4} from "../../src/interfaces/IMulticall_v4.sol";
import {ReentrancyLock} from "../../src/base/ReentrancyLock.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {PositionManager} from "../../src/PositionManager.sol";
import {PositionConfig} from "../shared/PositionConfig.sol";

import {LiquidityFuzzers} from "../shared/fuzz/LiquidityFuzzers.sol";
import {Planner, Plan} from "../shared/Planner.sol";
import {PosmTestSetup} from "../shared/PosmTestSetup.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";
import {Planner, Plan} from "../shared/Planner.sol";
import {DeltaResolver} from "../../src/base/DeltaResolver.sol";

import "forge-std/console2.sol";

contract PositionManagerModifyLiquiditiesTest is Test, PosmTestSetup, LiquidityFuzzers {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using Planner for Plan;

    PoolId poolId;
    address alice;
    uint256 alicePK;
    address bob;

    PositionConfig config;
    PositionConfig wethConfig;
    PositionConfig nativeConfig;

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
        // Deploys a hook which can accesses IPositionManager.modifyLiquiditiesWithoutUnlock
        deployPosmHookModifyLiquidities();
        seedBalance(address(hookModifyLiquidities));

        (key, poolId) = initPool(currency0, currency1, IHooks(hookModifyLiquidities), 3000, SQRT_PRICE_1_1);
        initWethPool(currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);

        seedWeth(address(this));
        approvePosmCurrency(Currency.wrap(address(_WETH9)));

        nativeKey = PoolKey(CurrencyLibrary.ADDRESS_ZERO, currency1, 3000, 60, IHooks(address(0)));
        manager.initialize(nativeKey, SQRT_PRICE_1_1);

        config = PositionConfig({poolKey: key, tickLower: -60, tickUpper: 60});
        wethConfig = PositionConfig({
            poolKey: wethKey,
            tickLower: TickMath.minUsableTick(wethKey.tickSpacing),
            tickUpper: TickMath.maxUsableTick(wethKey.tickSpacing)
        });
        nativeConfig = PositionConfig({poolKey: nativeKey, tickLower: -120, tickUpper: 120});

        vm.deal(address(this), 1000 ether);
    }

    /// @dev minting liquidity without approval is allowable
    function test_hook_mint() public {
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, address(this), ZERO_BYTES);

        // hook mints a new position in beforeSwap via hookData
        uint256 hookTokenId = lpm.nextTokenId();
        uint256 newLiquidity = 10e18;
        bytes memory calls = getMintEncoded(config, newLiquidity, address(hookModifyLiquidities), ZERO_BYTES);

        swap(key, true, -1e18, calls);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        // original liquidity unchanged
        assertEq(liquidity, initialLiquidity);

        // hook minted its own position
        liquidity = lpm.getPositionLiquidity(hookTokenId);
        assertEq(liquidity, newLiquidity);

        assertEq(lpm.ownerOf(tokenId), address(this)); // original position owned by this contract
        assertEq(lpm.ownerOf(hookTokenId), address(hookModifyLiquidities)); // hook position owned by hook
    }

    /// @dev hook must be approved to increase liquidity
    function test_hook_increaseLiquidity() public {
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, address(this), ZERO_BYTES);

        // approve the hook for increasing liquidity
        lpm.approve(address(hookModifyLiquidities), tokenId);

        // hook increases liquidity in beforeSwap via hookData
        uint256 newLiquidity = 10e18;
        bytes memory calls = getIncreaseEncoded(tokenId, config, newLiquidity, ZERO_BYTES);

        swap(key, true, -1e18, calls);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(liquidity, initialLiquidity + newLiquidity);
    }

    /// @dev hook can decrease liquidity with approval
    function test_hook_decreaseLiquidity() public {
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, address(this), ZERO_BYTES);

        // approve the hook for decreasing liquidity
        lpm.approve(address(hookModifyLiquidities), tokenId);

        // hook decreases liquidity in beforeSwap via hookData
        uint256 liquidityToDecrease = 10e18;
        bytes memory calls = getDecreaseEncoded(tokenId, config, liquidityToDecrease, ZERO_BYTES);

        swap(key, true, -1e18, calls);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(liquidity, initialLiquidity - liquidityToDecrease);
    }

    /// @dev hook can collect liquidity with approval
    function test_hook_collect() public {
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, address(this), ZERO_BYTES);

        // approve the hook for collecting liquidity
        lpm.approve(address(hookModifyLiquidities), tokenId);

        // donate to generate revenue
        uint256 feeRevenue0 = 1e18;
        uint256 feeRevenue1 = 0.1e18;
        donateRouter.donate(config.poolKey, feeRevenue0, feeRevenue1, ZERO_BYTES);

        uint256 balance0HookBefore = currency0.balanceOf(address(hookModifyLiquidities));
        uint256 balance1HookBefore = currency1.balanceOf(address(hookModifyLiquidities));

        // hook collects liquidity in beforeSwap via hookData
        bytes memory calls = getCollectEncoded(tokenId, config, ZERO_BYTES);
        swap(key, true, -1e18, calls);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        // liquidity unchanged
        assertEq(liquidity, initialLiquidity);

        // hook collected the fee revenue
        assertEq(currency0.balanceOf(address(hookModifyLiquidities)), balance0HookBefore + feeRevenue0 - 1 wei); // imprecision, core is keeping 1 wei
        assertEq(currency1.balanceOf(address(hookModifyLiquidities)), balance1HookBefore + feeRevenue1 - 1 wei);
    }

    /// @dev hook can burn liquidity with approval
    function test_hook_burn() public {
        // mint some liquidity that is NOT burned in beforeSwap
        mint(config, 100e18, address(this), ZERO_BYTES);

        // the position to be burned by the hook
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, address(this), ZERO_BYTES);
        // TODO: make this less jank since HookModifyLiquidites also has delta saving capabilities
        // BalanceDelta mintDelta = getLastDelta();
        BalanceDelta mintDelta = hookModifyLiquidities.deltas(hookModifyLiquidities.numberDeltasReturned() - 1);

        // approve the hook for burning liquidity
        lpm.approve(address(hookModifyLiquidities), tokenId);

        uint256 balance0HookBefore = currency0.balanceOf(address(hookModifyLiquidities));
        uint256 balance1HookBefore = currency1.balanceOf(address(hookModifyLiquidities));

        // hook burns liquidity in beforeSwap via hookData
        bytes memory calls = getBurnEncoded(tokenId, config, ZERO_BYTES);
        swap(key, true, -1e18, calls);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        // liquidity burned
        assertEq(liquidity, 0);
        // 721 will revert if the token does not exist
        vm.expectRevert();
        lpm.ownerOf(tokenId);

        // hook claimed the burned liquidity
        assertEq(
            currency0.balanceOf(address(hookModifyLiquidities)),
            balance0HookBefore + uint128(-mintDelta.amount0() - 1 wei) // imprecision since core is keeping 1 wei
        );
        assertEq(
            currency1.balanceOf(address(hookModifyLiquidities)),
            balance1HookBefore + uint128(-mintDelta.amount1() - 1 wei)
        );
    }

    // --- Revert Scenarios --- //
    /// @dev Hook does not have approval so increasing liquidity should revert
    function test_hook_increaseLiquidity_revert() public {
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, address(this), ZERO_BYTES);

        // hook decreases liquidity in beforeSwap via hookData
        uint256 liquidityToAdd = 10e18;
        bytes memory calls = getIncreaseEncoded(tokenId, config, liquidityToAdd, ZERO_BYTES);

        // should revert because hook is not approved
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hookModifyLiquidities),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(IPositionManager.NotApproved.selector, address(hookModifyLiquidities)),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(key, true, -1e18, calls);
    }

    /// @dev Hook does not have approval so decreasing liquidity should revert
    function test_hook_decreaseLiquidity_revert() public {
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, address(this), ZERO_BYTES);

        // hook decreases liquidity in beforeSwap via hookData
        uint256 liquidityToDecrease = 10e18;
        bytes memory calls = getDecreaseEncoded(tokenId, config, liquidityToDecrease, ZERO_BYTES);

        // should revert because hook is not approved
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hookModifyLiquidities),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(IPositionManager.NotApproved.selector, address(hookModifyLiquidities)),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(key, true, -1e18, calls);
    }

    /// @dev hook does not have approval so collecting liquidity should revert
    function test_hook_collect_revert() public {
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, address(this), ZERO_BYTES);

        // donate to generate revenue
        uint256 feeRevenue0 = 1e18;
        uint256 feeRevenue1 = 0.1e18;
        donateRouter.donate(config.poolKey, feeRevenue0, feeRevenue1, ZERO_BYTES);

        // hook collects liquidity in beforeSwap via hookData
        bytes memory calls = getCollectEncoded(tokenId, config, ZERO_BYTES);

        // should revert because hook is not approved
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hookModifyLiquidities),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(IPositionManager.NotApproved.selector, address(hookModifyLiquidities)),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(key, true, -1e18, calls);
    }

    /// @dev hook does not have approval so burning liquidity should revert
    function test_hook_burn_revert() public {
        // the position to be burned by the hook
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, address(this), ZERO_BYTES);

        // hook burns liquidity in beforeSwap via hookData
        bytes memory calls = getBurnEncoded(tokenId, config, ZERO_BYTES);

        // should revert because hook is not approved
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hookModifyLiquidities),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(IPositionManager.NotApproved.selector, address(hookModifyLiquidities)),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(key, true, -1e18, calls);
    }

    /// @dev hook cannot re-enter modifyLiquiditiesWithoutUnlock in beforeRemoveLiquidity
    function test_hook_increaseLiquidity_reenter_revert() public {
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, address(this), ZERO_BYTES);

        uint256 newLiquidity = 10e18;

        // to be provided as hookData, so beforeAddLiquidity attempts to increase liquidity
        bytes memory hookCall = getIncreaseEncoded(tokenId, config, newLiquidity, ZERO_BYTES);
        bytes memory calls = getIncreaseEncoded(tokenId, config, newLiquidity, hookCall);

        // should revert because hook is re-entering modifyLiquiditiesWithoutUnlock
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hookModifyLiquidities),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(ReentrancyLock.ContractLocked.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        lpm.modifyLiquidities(calls, _deadline);
    }

    function test_wrap_mint_usingContractBalance() public {
        // weth-currency1 pool initialized as wethKey
        // input: eth, currency1
        // modifyLiquidities call to mint liquidity weth and currency1
        // 1 _wrap with contract balance
        // 2 _mint
        // 3 _settle weth where the payer is the contract
        // 4 _close currency1, payer is caller
        // 5 _sweep weth since eth was entirely wrapped

        uint256 balanceEthBefore = address(this).balance;
        uint256 balance1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        uint256 tokenId = lpm.nextTokenId();

        uint128 liquidityAmount = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(wethConfig.tickLower),
            TickMath.getSqrtPriceAtTick(wethConfig.tickUpper),
            100 ether,
            100 ether
        );

        Plan memory planner = Planner.init();
        planner.add(Actions.WRAP, abi.encode(ActionConstants.CONTRACT_BALANCE));
        planner.add(
            Actions.MINT_POSITION,
            abi.encode(
                wethConfig.poolKey,
                wethConfig.tickLower,
                wethConfig.tickUpper,
                liquidityAmount,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );

        // weth9 payer is the contract
        planner.add(Actions.SETTLE, abi.encode(address(_WETH9), ActionConstants.OPEN_DELTA, false));
        // other currency can close normally
        planner.add(Actions.CLOSE_CURRENCY, abi.encode(currency1));
        // we wrapped the full contract balance so we sweep back in the wrapped currency
        planner.add(Actions.SWEEP, abi.encode(address(_WETH9), ActionConstants.MSG_SENDER));
        bytes memory actions = planner.encode();

        // Overestimate eth amount.
        lpm.modifyLiquidities{value: 102 ether}(actions, _deadline);

        uint256 balanceEthAfter = address(this).balance;
        uint256 balance1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        // The full eth amount was "spent" because some was wrapped into weth and refunded.
        assertApproxEqAbs(balanceEthBefore - balanceEthAfter, 102 ether, 1 wei);
        assertApproxEqAbs(balance1Before - balance1After, 100 ether, 1 wei);
        assertEq(lpm.ownerOf(tokenId), address(this));
        assertEq(lpm.getPositionLiquidity(tokenId), liquidityAmount);
        assertEq(_WETH9.balanceOf(address(lpm)), 0);
        assertEq(address(lpm).balance, 0);
    }

    function test_wrap_mint_openDelta() public {
        // weth-currency1 pool initialized as wethKey
        // input: eth, currency1
        // modifyLiquidities call to mint liquidity weth and currency1
        // 1 _mint
        // 2 _wrap with open delta
        // 3 _settle weth where the payer is the contract
        // 4 _close currency1, payer is caller
        // 5 _sweep eth since only the open delta amount was wrapped

        uint256 balanceEthBefore = address(this).balance;
        uint256 balance1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        uint256 tokenId = lpm.nextTokenId();

        uint128 liquidityAmount = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(wethConfig.tickLower),
            TickMath.getSqrtPriceAtTick(wethConfig.tickUpper),
            100 ether,
            100 ether
        );

        Plan memory planner = Planner.init();

        planner.add(
            Actions.MINT_POSITION,
            abi.encode(
                wethConfig.poolKey,
                wethConfig.tickLower,
                wethConfig.tickUpper,
                liquidityAmount,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );

        planner.add(Actions.WRAP, abi.encode(ActionConstants.OPEN_DELTA));

        // weth9 payer is the contract
        planner.add(Actions.SETTLE, abi.encode(address(_WETH9), ActionConstants.OPEN_DELTA, false));
        // other currency can close normally
        planner.add(Actions.CLOSE_CURRENCY, abi.encode(currency1));
        // we wrapped the open delta balance so we sweep back in the native currency
        planner.add(Actions.SWEEP, abi.encode(CurrencyLibrary.ADDRESS_ZERO, ActionConstants.MSG_SENDER));
        bytes memory actions = planner.encode();

        lpm.modifyLiquidities{value: 102 ether}(actions, _deadline);

        uint256 balanceEthAfter = address(this).balance;
        uint256 balance1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        // Approx 100 eth was spent because the extra 2 were refunded.
        assertApproxEqAbs(balanceEthBefore - balanceEthAfter, 100 ether, 1 wei);
        assertApproxEqAbs(balance1Before - balance1After, 100 ether, 1 wei);
        assertEq(lpm.ownerOf(tokenId), address(this));
        assertEq(lpm.getPositionLiquidity(tokenId), liquidityAmount);
        assertEq(_WETH9.balanceOf(address(lpm)), 0);
        assertEq(address(lpm).balance, 0);
    }

    function test_wrap_mint_usingExactAmount() public {
        // weth-currency1 pool initialized as wethKey
        // input: eth, currency1
        // modifyLiquidities call to mint liquidity weth and currency1
        // 1 _wrap with an amount
        // 2 _mint
        // 3 _settle weth where the payer is the contract
        // 4 _close currency1, payer is caller
        // 5 _sweep weth since eth was entirely wrapped

        uint256 balanceEthBefore = address(this).balance;
        uint256 balance1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        uint256 tokenId = lpm.nextTokenId();

        uint128 liquidityAmount = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(wethConfig.tickLower),
            TickMath.getSqrtPriceAtTick(wethConfig.tickUpper),
            100 ether,
            100 ether
        );

        Plan memory planner = Planner.init();
        planner.add(Actions.WRAP, abi.encode(100 ether));
        planner.add(
            Actions.MINT_POSITION,
            abi.encode(
                wethConfig.poolKey,
                wethConfig.tickLower,
                wethConfig.tickUpper,
                liquidityAmount,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );

        // weth9 payer is the contract
        planner.add(Actions.SETTLE, abi.encode(address(_WETH9), ActionConstants.OPEN_DELTA, false));
        // other currency can close normally
        planner.add(Actions.CLOSE_CURRENCY, abi.encode(currency1));
        // we wrapped all 100 eth so we sweep back in the wrapped currency for safety measure
        planner.add(Actions.SWEEP, abi.encode(address(_WETH9), ActionConstants.MSG_SENDER));
        bytes memory actions = planner.encode();

        lpm.modifyLiquidities{value: 100 ether}(actions, _deadline);

        uint256 balanceEthAfter = address(this).balance;
        uint256 balance1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        // The full eth amount was "spent" because some was wrapped into weth and refunded.
        assertApproxEqAbs(balanceEthBefore - balanceEthAfter, 100 ether, 1 wei);
        assertApproxEqAbs(balance1Before - balance1After, 100 ether, 1 wei);
        assertEq(lpm.ownerOf(tokenId), address(this));
        assertEq(lpm.getPositionLiquidity(tokenId), liquidityAmount);
        assertEq(_WETH9.balanceOf(address(lpm)), 0);
        assertEq(address(lpm).balance, 0);
    }

    function test_wrap_mint_revertsInsufficientBalance() public {
        // 1 _wrap with more eth than is sent in

        Plan memory planner = Planner.init();
        // Wrap more eth than what is sent in.
        planner.add(Actions.WRAP, abi.encode(101 ether));

        bytes memory actions = planner.encode();

        vm.expectRevert(DeltaResolver.InsufficientBalance.selector);
        lpm.modifyLiquidities{value: 100 ether}(actions, _deadline);
    }

    function test_unwrap_usingContractBalance() public {
        // weth-currency1 pool
        // output: eth, currency1
        // modifyLiquidities call to mint liquidity weth and currency1
        // 1 _burn
        // 2 _take where the weth is sent to the lpm contract
        // 3 _take where currency1 is sent to the msg sender
        // 4 _unwrap using contract balance
        // 5 _sweep where eth is sent to msg sender
        uint256 tokenId = lpm.nextTokenId();

        uint128 liquidityAmount = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(wethConfig.tickLower),
            TickMath.getSqrtPriceAtTick(wethConfig.tickUpper),
            100 ether,
            100 ether
        );

        bytes memory actions = getMintEncoded(wethConfig, liquidityAmount, address(this), ZERO_BYTES);
        lpm.modifyLiquidities(actions, _deadline);

        assertEq(lpm.getPositionLiquidity(tokenId), liquidityAmount);

        uint256 balanceEthBefore = address(this).balance;
        uint256 balance1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        Plan memory planner = Planner.init();
        planner.add(
            Actions.BURN_POSITION, abi.encode(tokenId, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
        );
        // take the weth to the position manager to be unwrapped
        planner.add(Actions.TAKE, abi.encode(address(_WETH9), ActionConstants.ADDRESS_THIS, ActionConstants.OPEN_DELTA));
        planner.add(
            Actions.TAKE,
            abi.encode(address(Currency.unwrap(currency1)), ActionConstants.MSG_SENDER, ActionConstants.OPEN_DELTA)
        );
        planner.add(Actions.UNWRAP, abi.encode(ActionConstants.CONTRACT_BALANCE));
        planner.add(Actions.SWEEP, abi.encode(CurrencyLibrary.ADDRESS_ZERO, ActionConstants.MSG_SENDER));

        actions = planner.encode();

        lpm.modifyLiquidities(actions, _deadline);

        uint256 balanceEthAfter = address(this).balance;
        uint256 balance1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        assertApproxEqAbs(balanceEthAfter - balanceEthBefore, 100 ether, 1 wei);
        assertApproxEqAbs(balance1After - balance1Before, 100 ether, 1 wei);
        assertEq(lpm.getPositionLiquidity(tokenId), 0);
        assertEq(_WETH9.balanceOf(address(lpm)), 0);
        assertEq(address(lpm).balance, 0);
    }

    function test_unwrap_openDelta_reinvest() public {
        // weth-currency1 pool rolls half to eth-currency1 pool
        // output: eth, currency1
        // modifyLiquidities call to mint liquidity weth and currency1
        // 1 _burn (weth-currency1)
        // 2 _take where the weth is sent to the lpm contract
        // 4 _mint to an eth pool
        // 4 _unwrap using open delta (pool managers ETH balance)
        // 3 _take where leftover currency1 is sent to the msg sender
        // 5 _settle eth open delta
        // 5 _sweep leftover weth

        uint256 tokenId = lpm.nextTokenId();

        uint128 liquidityAmount = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(wethConfig.tickLower),
            TickMath.getSqrtPriceAtTick(wethConfig.tickUpper),
            100 ether,
            100 ether
        );

        bytes memory actions = getMintEncoded(wethConfig, liquidityAmount, address(this), ZERO_BYTES);
        lpm.modifyLiquidities(actions, _deadline);

        assertEq(lpm.getPositionLiquidity(tokenId), liquidityAmount);

        uint256 balanceEthBefore = address(this).balance;
        uint256 balance1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        uint256 balanceWethBefore = _WETH9.balanceOf(address(this));

        uint128 newLiquidityAmount = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(nativeConfig.tickLower),
            TickMath.getSqrtPriceAtTick(nativeConfig.tickUpper),
            50 ether,
            50 ether
        );

        Plan memory planner = Planner.init();
        planner.add(
            Actions.BURN_POSITION, abi.encode(tokenId, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
        );
        // take the weth to the position manager to be unwrapped
        planner.add(Actions.TAKE, abi.encode(address(_WETH9), ActionConstants.ADDRESS_THIS, ActionConstants.OPEN_DELTA));
        planner.add(
            Actions.MINT_POSITION,
            abi.encode(
                nativeConfig.poolKey,
                nativeConfig.tickLower,
                nativeConfig.tickUpper,
                newLiquidityAmount,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );
        planner.add(Actions.UNWRAP, abi.encode(ActionConstants.OPEN_DELTA));
        // pay the eth
        planner.add(Actions.SETTLE, abi.encode(CurrencyLibrary.ADDRESS_ZERO, ActionConstants.OPEN_DELTA, false));
        // take the leftover currency1
        planner.add(
            Actions.TAKE,
            abi.encode(address(Currency.unwrap(currency1)), ActionConstants.MSG_SENDER, ActionConstants.OPEN_DELTA)
        );
        planner.add(Actions.SWEEP, abi.encode(address(_WETH9), ActionConstants.MSG_SENDER));

        actions = planner.encode();

        lpm.modifyLiquidities(actions, _deadline);

        uint256 balanceEthAfter = address(this).balance;
        uint256 balance1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        uint256 balanceWethAfter = _WETH9.balanceOf(address(this));

        // Eth balance should not change.
        assertEq(balanceEthAfter, balanceEthBefore);
        // Only half of the original liquidity was reinvested.
        assertApproxEqAbs(balance1After - balance1Before, 50 ether, 1 wei);
        assertApproxEqAbs(balanceWethAfter - balanceWethBefore, 50 ether, 1 wei);
        assertEq(lpm.getPositionLiquidity(tokenId), 0);
        assertEq(_WETH9.balanceOf(address(lpm)), 0);
        assertEq(address(lpm).balance, 0);
    }

    function test_unwrap_revertsInsufficientBalance() public {
        // 1 _unwrap with more than is in the contract

        Plan memory planner = Planner.init();
        // unwraps more eth than what is in the contract
        planner.add(Actions.UNWRAP, abi.encode(101 ether));

        bytes memory actions = planner.encode();

        vm.expectRevert(DeltaResolver.InsufficientBalance.selector);
        lpm.modifyLiquidities(actions, _deadline);
    }
}
