// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
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

import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {ReentrancyLock} from "../../src/base/ReentrancyLock.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {PositionManager} from "../../src/PositionManager.sol";
import {PositionConfig} from "../shared/PositionConfig.sol";

import {LiquidityFuzzers} from "../shared/fuzz/LiquidityFuzzers.sol";
import {Planner, Plan} from "../shared/Planner.sol";
import {PosmTestSetup} from "../shared/PosmTestSetup.sol";

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
        // Deploys a hook which can accesses IPositionManager.modifyLiquiditiesWithoutUnlock
        deployPosmHookModifyLiquidities();
        seedBalance(address(hookModifyLiquidities));

        (key, poolId) = initPool(currency0, currency1, IHooks(hookModifyLiquidities), 3000, SQRT_PRICE_1_1, ZERO_BYTES);

        config = PositionConfig({poolKey: key, tickLower: -60, tickUpper: 60});
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
                Hooks.Wrap__FailedHookCall.selector,
                address(hookModifyLiquidities),
                abi.encodeWithSelector(IPositionManager.NotApproved.selector, address(hookModifyLiquidities))
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
                Hooks.Wrap__FailedHookCall.selector,
                address(hookModifyLiquidities),
                abi.encodeWithSelector(IPositionManager.NotApproved.selector, address(hookModifyLiquidities))
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
                Hooks.Wrap__FailedHookCall.selector,
                address(hookModifyLiquidities),
                abi.encodeWithSelector(IPositionManager.NotApproved.selector, address(hookModifyLiquidities))
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
                Hooks.Wrap__FailedHookCall.selector,
                address(hookModifyLiquidities),
                abi.encodeWithSelector(IPositionManager.NotApproved.selector, address(hookModifyLiquidities))
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
                Hooks.Wrap__FailedHookCall.selector,
                address(hookModifyLiquidities),
                abi.encodeWithSelector(ReentrancyLock.ContractLocked.selector)
            )
        );
        lpm.modifyLiquidities(calls, _deadline);
    }
}
