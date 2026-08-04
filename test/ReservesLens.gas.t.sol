// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IReservesLens} from "../src/interfaces/IReservesLens.sol";
import {ReservesLens} from "../src/lens/ReservesLens.sol";

/// @notice Stable synthetic gas baselines. Real-pool distributions are produced by the fork comparison harness.
contract ReservesLensGasTest is Test, Deployers {
    ReservesLens internal lens;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        lens = new ReservesLens();
    }

    function test_gas_bytecodeSize() public {
        vm.snapshotValue("ReservesLens_Bytecode", address(lens).code.length);
    }

    function test_reservesLens_initcodeHash() public {
        vm.snapshotValue(
            "ReservesLens initcode hash (as uint256)", uint256(keccak256(vm.getCode("ReservesLens.sol:ReservesLens")))
        );
    }

    function test_gas_singleShot_emptyTickSpacingOne() public {
        PoolKey memory spacingOne = PoolKey(currency0, currency1, 100, 1, IHooks(address(0)));
        manager.initialize(spacingOne, SQRT_PRICE_1_1);

        uint256 gasBefore = gasleft();
        IReservesLens.PoolTVL memory result = lens.getPoolTVL(manager, spacingOne, address(0));
        uint256 gasUsed = gasBefore - gasleft();
        vm.snapshotGasLastCall("ReservesLens_empty_tickSpacingOne_singleShot");

        assertEq(result.coreAmount0, 0);
        assertEq(result.coreAmount1, 0);
        assertLt(gasUsed, 40_000_000, "unexpected regression in the tick-spacing-one baseline");
        emit log_named_uint("empty tickSpacing=1 single-shot gas", gasUsed);
    }

    function test_gas_page512_emptyTickSpacingOne() public {
        PoolKey memory spacingOne = PoolKey(currency0, currency1, 100, 1, IHooks(address(0)));
        manager.initialize(spacingOne, SQRT_PRICE_1_1);

        uint256 gasBefore = gasleft();
        (, bytes memory cursor, bool done) = lens.getPoolTVLPaged(manager, spacingOne, address(0), bytes(""), 512);
        uint256 gasUsed = gasBefore - gasleft();
        vm.snapshotGasLastCall("ReservesLens_empty_tickSpacingOne_page512");

        assertFalse(done);
        assertGt(cursor.length, 0);
        assertLt(gasUsed, 3_000_000, "recommended page should fit conservative provider caps");
        emit log_named_uint("empty tickSpacing=1 512-read page gas", gasUsed);
    }
}
