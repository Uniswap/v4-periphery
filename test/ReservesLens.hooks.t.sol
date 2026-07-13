// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IReservesLens} from "../src/interfaces/IReservesLens.sol";
import {ReservesLens} from "../src/lens/ReservesLens.sol";
import {MockHookStats} from "./mocks/MockHookStats.sol";

contract ReservesLensHookTest is Test, Deployers {
    ReservesLens internal lens;
    address internal hookAddress;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        lens = new ReservesLens();
        hookAddress = address(uint160(0x10000 | Hooks.BEFORE_SWAP_FLAG));
    }

    function test_directHookStats() public {
        key = _initializeHookPool(MockHookStats.Mode.VALID);
        IReservesLens.PoolTVL memory result = lens.getPoolTVL(manager, key, address(0));
        assertEq(result.hookReserves0, 1000);
        assertEq(result.hookReserves1, 2000);
        assertEq(result.hookEffective0, 500);
        assertEq(result.hookEffective1, 1000);
        assertEq(result.statsProvider, hookAddress);
        assertEq(uint8(result.statsStatus), uint8(IReservesLens.HookStatsStatus.DIRECT));
        assertEq(result.hookPermissions, uint16(Hooks.BEFORE_SWAP_FLAG));
        assertFalse(result.hasCustomAccounting);
    }

    function test_customAccountingPermissionIsDecoded() public {
        hookAddress = address(uint160(0x10000 | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG));
        key = _initializeHookPool(MockHookStats.Mode.VALID);
        IReservesLens.PoolTVL memory result = lens.getPoolTVL(manager, key, address(0));
        assertTrue(result.hasCustomAccounting);
    }

    function test_externalHookStats() public {
        key = _initializeHookPool(MockHookStats.Mode.VALID);
        MockHookStats provider = new MockHookStats(hookAddress, MockHookStats.Mode.VALID);
        IReservesLens.PoolTVL memory result = lens.getPoolTVL(manager, key, address(provider));
        assertEq(result.hookReserves0, 1000);
        assertEq(result.statsProvider, address(provider));
        assertEq(uint8(result.statsStatus), uint8(IReservesLens.HookStatsStatus.EXTERNAL));
    }

    function test_nonSupportingHookDoesNotRevertCore() public {
        key = _initializeHookPool(MockHookStats.Mode.UNIVERSAL_ERC165);
        IReservesLens.PoolTVL memory result = lens.getPoolTVL(manager, key, address(0));
        assertEq(result.coreAmount0, 0);
        assertEq(result.coreAmount1, 0);
        assertEq(uint8(result.statsStatus), uint8(IReservesLens.HookStatsStatus.NOT_SUPPORTED));
    }

    function test_revertingProviderDoesNotRevertCore() public {
        key = _initializeHookPool(MockHookStats.Mode.REVERT_STATS);
        IReservesLens.PoolTVL memory result = lens.getPoolTVL(manager, key, address(0));
        assertEq(result.coreAmount0, 0);
        assertEq(uint8(result.statsStatus), uint8(IReservesLens.HookStatsStatus.CALL_FAILED));
    }

    function test_wrongHookPointerIsInvalidProvider() public {
        key = _initializeHookPool(MockHookStats.Mode.WRONG_HOOK);
        IReservesLens.PoolTVL memory result = lens.getPoolTVL(manager, key, address(0));
        assertEq(uint8(result.statsStatus), uint8(IReservesLens.HookStatsStatus.INVALID_PROVIDER));
    }

    function test_effectiveGreaterThanReservesIsInvalid() public {
        key = _initializeHookPool(MockHookStats.Mode.INVALID_EFFECTIVE);
        IReservesLens.PoolTVL memory result = lens.getPoolTVL(manager, key, address(0));
        assertEq(result.hookReserves0, 0);
        assertEq(result.hookEffective0, 0);
        assertEq(uint8(result.statsStatus), uint8(IReservesLens.HookStatsStatus.INVALID_RESPONSE));
    }

    function test_returnBombIsBoundedAndInvalid() public {
        key = _initializeHookPool(MockHookStats.Mode.RETURN_BOMB);
        uint256 gasBefore = gasleft();
        IReservesLens.PoolTVL memory result = lens.getPoolTVL(manager, key, address(0));
        uint256 gasUsed = gasBefore - gasleft();
        assertEq(uint8(result.statsStatus), uint8(IReservesLens.HookStatsStatus.INVALID_RESPONSE));
        assertLt(gasUsed, 2_000_000);
    }

    function test_shortReturnIsInvalid() public {
        key = _initializeHookPool(MockHookStats.Mode.SHORT_RETURN);
        IReservesLens.PoolTVL memory result = lens.getPoolTVL(manager, key, address(0));
        assertEq(uint8(result.statsStatus), uint8(IReservesLens.HookStatsStatus.INVALID_RESPONSE));
    }

    function test_gasGriefingProviderIsCapped() public {
        key = _initializeHookPool(MockHookStats.Mode.GAS_BURN);
        uint256 gasBefore = gasleft();
        IReservesLens.PoolTVL memory result = lens.getPoolTVL(manager, key, address(0));
        uint256 gasUsed = gasBefore - gasleft();
        assertEq(uint8(result.statsStatus), uint8(IReservesLens.HookStatsStatus.CALL_FAILED));
        assertLt(gasUsed, 2_000_000);
    }

    function test_insufficientGasForHookStatsRevertsInsteadOfMisclassifying() public {
        key = _initializeHookPool(MockHookStats.Mode.VALID);
        // Enough gas to complete the core scan and ERC165 probe, but not enough to guarantee the 500k
        // hook-stats stipend after the EIP-150 63/64 reduction. Without the guard this healthy provider
        // would be gas-starved and misreported as CALL_FAILED.
        vm.expectRevert(IReservesLens.InsufficientGasForHookStats.selector);
        lens.getPoolTVL{gas: 650_000}(manager, key, address(0));
    }

    function test_EOAExternalProviderIsInvalid() public {
        key = _initializeHookPool(MockHookStats.Mode.VALID);
        IReservesLens.PoolTVL memory result = lens.getPoolTVL(manager, key, address(0xbeef));
        assertEq(uint8(result.statsStatus), uint8(IReservesLens.HookStatsStatus.INVALID_PROVIDER));
    }

    function _initializeHookPool(MockHookStats.Mode mode) private returns (PoolKey memory poolKey) {
        MockHookStats implementation = new MockHookStats(hookAddress, mode);
        vm.etch(hookAddress, address(implementation).code);
        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hookAddress));
        manager.initialize(poolKey, SQRT_PRICE_1_1);
    }
}
