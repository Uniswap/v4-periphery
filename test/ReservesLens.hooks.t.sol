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

    function test_insufficientGasReportsStatusInsteadOfMisclassifying() public {
        key = _initializeHookPool(MockHookStats.Mode.VALID);
        IReservesLens.PoolTVL memory expected = lens.getPoolTVL(manager, key, address(0));
        // Enough gas to complete the core scan, but not enough to guarantee the ERC165 probes and the
        // three 500k hook-stats stipends after the EIP-150 63/64 reduction. Core amounts must come back
        // intact with an honest INSUFFICIENT_GAS label instead of a revert or a CALL_FAILED
        // misclassification of this healthy provider.
        IReservesLens.PoolTVL memory result = lens.getPoolTVL{gas: 1_000_000}(manager, key, address(0));
        assertEq(uint8(result.statsStatus), uint8(IReservesLens.HookStatsStatus.INSUFFICIENT_GAS));
        assertEq(result.coreAmount0, expected.coreAmount0);
        assertEq(result.coreAmount1, expected.coreAmount1);
        assertEq(result.statsProvider, hookAddress);
        assertEq(result.hookReserves0, 0);
        assertEq(result.hookReserves1, 0);
    }

    function test_explicitHookProviderIsDirect() public {
        key = _initializeHookPool(MockHookStats.Mode.VALID);
        IReservesLens.PoolTVL memory result = lens.getPoolTVL(manager, key, hookAddress);
        assertEq(result.statsProvider, hookAddress);
        assertEq(uint8(result.statsStatus), uint8(IReservesLens.HookStatsStatus.DIRECT));
    }

    function test_nonSupportingExplicitHookProviderIsNotSupported() public {
        key = _initializeHookPool(MockHookStats.Mode.UNIVERSAL_ERC165);
        IReservesLens.PoolTVL memory result = lens.getPoolTVL(manager, key, hookAddress);
        assertEq(uint8(result.statsStatus), uint8(IReservesLens.HookStatsStatus.NOT_SUPPORTED));
    }

    function test_defaultVariantProbesHookDirectly() public {
        key = _initializeHookPool(MockHookStats.Mode.VALID);
        IReservesLens.PoolTVL memory result = lens.getPoolTVL(manager, key);
        assertEq(uint8(result.statsStatus), uint8(IReservesLens.HookStatsStatus.DIRECT));
        assertEq(result.hookReserves0, 1000);
        assertEq(result.statsProvider, hookAddress);
    }

    function test_pagedFinalPageProbesHookStats() public {
        key = _initializeHookPool(MockHookStats.Mode.VALID);
        IReservesLens.PoolTVL memory result;
        bytes memory cursor;
        bool done;
        uint256 pages;
        while (!done) {
            (result, cursor, done) = lens.getPoolTVLPaged(manager, key, address(0), cursor, 2);
            pages++;
            assertLt(pages, 1000);
        }
        assertGt(pages, 1);
        assertEq(uint8(result.statsStatus), uint8(IReservesLens.HookStatsStatus.DIRECT));
        assertEq(result.hookReserves0, 1000);
        assertEq(result.hookReserves1, 2000);
        assertEq(result.hookEffective0, 500);
        assertEq(result.hookEffective1, 1000);
        assertEq(result.statsProvider, hookAddress);
    }

    function test_pagedFinalPageInsufficientGasKeepsCoreResult() public {
        key = _initializeHookPool(MockHookStats.Mode.VALID);
        IReservesLens.PoolTVL memory expected = lens.getPoolTVL(manager, key, address(0));
        // The default 512-read budget covers this pool in a single page, and 1M gas completes the scan but
        // cannot guarantee the hook-stats probe sequence: the page must come back done with intact core
        // amounts and an honest INSUFFICIENT_GAS label.
        (IReservesLens.PoolTVL memory result,, bool done) =
            lens.getPoolTVLPaged{gas: 1_000_000}(manager, key, bytes(""));
        assertTrue(done);
        assertEq(uint8(result.statsStatus), uint8(IReservesLens.HookStatsStatus.INSUFFICIENT_GAS));
        assertEq(result.coreAmount0, expected.coreAmount0);
        assertEq(result.coreAmount1, expected.coreAmount1);
        assertEq(result.hookReserves0, 0);
    }

    function test_EOAExternalProviderIsInvalid() public {
        key = _initializeHookPool(MockHookStats.Mode.VALID);
        IReservesLens.PoolTVL memory result = lens.getPoolTVL(manager, key, address(0xbeef));
        assertEq(uint8(result.statsStatus), uint8(IReservesLens.HookStatsStatus.INVALID_PROVIDER));
    }

    /// @dev The hook-stats path must degrade to INSUFFICIENT_GAS at ANY gas budget, never revert away the core
    ///      scan. The stipend-boundary check inside _boundedStaticcall is exercised by a provider that legally
    ///      consumes nearly its full stipend on every call, so a caller landing between the up-front budget check
    ///      and the per-call threshold degrades instead of reverting. Core amounts must be intact either way.
    function testFuzz_hookStats_anyGasBudgetDegradesNeverReverts(uint32 rawGas) public {
        key = _initializeHookPool(MockHookStats.Mode.VALID_GAS_HEAVY);
        IReservesLens.PoolTVL memory expected = lens.getPoolTVL(manager, key, address(0));
        assertEq(uint8(expected.statsStatus), uint8(IReservesLens.HookStatsStatus.DIRECT));

        // Lower bound comfortably covers the core scan so an out-of-gas in the scan itself (an ordinary OOG,
        // not the guarantee under test) cannot trip the fuzz run; upper bound is well past the stats budget.
        uint256 gasBudget = bound(uint256(rawGas), 900_000, 3_000_000);
        IReservesLens.PoolTVL memory result = lens.getPoolTVL{gas: gasBudget}(manager, key, address(0));

        assertEq(result.coreAmount0, expected.coreAmount0);
        assertEq(result.coreAmount1, expected.coreAmount1);
        assertEq(result.activeLiquidity, expected.activeLiquidity);
        if (result.statsStatus == IReservesLens.HookStatsStatus.DIRECT) {
            assertEq(result.hookReserves0, expected.hookReserves0);
            assertEq(result.hookReserves1, expected.hookReserves1);
        } else {
            assertEq(uint8(result.statsStatus), uint8(IReservesLens.HookStatsStatus.INSUFFICIENT_GAS));
            assertEq(result.hookReserves0, 0);
            assertEq(result.hookReserves1, 0);
        }
    }

    function _initializeHookPool(MockHookStats.Mode mode) private returns (PoolKey memory poolKey) {
        MockHookStats implementation = new MockHookStats(hookAddress, mode);
        vm.etch(hookAddress, address(implementation).code);
        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hookAddress));
        manager.initialize(poolKey, SQRT_PRICE_1_1);
    }
}
