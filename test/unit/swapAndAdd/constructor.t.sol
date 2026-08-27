// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ISwapAndAdd} from "../../../src/interfaces/ISwapAndAdd.sol";

interface IZapWiring {
    function poolManager() external view returns (address);
    function permit2() external view returns (address);
    function positionManager() external view returns (address);
    function universalRouter() external view returns (address);
}

/// @notice Constructor branches: each immutable is zero-checked, and a valid deploy stores all four args.
///         Deployed via raw `create` on the compiled artifact — `deployCode` swallows creation revert data.
contract ConstructorTest is Test {
    address poolManager = makeAddr("poolManager");
    address permit2 = makeAddr("permit2");
    address positionManager = makeAddr("positionManager");
    address universalRouter = makeAddr("universalRouter");

    /// @dev external so vm.expectRevert can observe the bubbled creation revert.
    function deployZap(address _pm, address _p2, address _posm, address _ur) external returns (address deployed) {
        bytes memory initcode =
            abi.encodePacked(vm.getCode("SwapAndAdd.sol:SwapAndAdd"), abi.encode(_pm, _p2, _posm, _ur));
        assembly ("memory-safe") {
            deployed := create(0, add(initcode, 0x20), mload(initcode))
            if iszero(deployed) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }

    function test_WhenPoolManagerIsZero() public {
        // it reverts with {ZeroAddress}
        vm.expectRevert(ISwapAndAdd.ZeroAddress.selector);
        this.deployZap(address(0), permit2, positionManager, universalRouter);
    }

    function test_WhenPermit2IsZero() public {
        // it reverts with {ZeroAddress}
        vm.expectRevert(ISwapAndAdd.ZeroAddress.selector);
        this.deployZap(poolManager, address(0), positionManager, universalRouter);
    }

    function test_WhenPositionManagerIsZero() public {
        // it reverts with {ZeroAddress}
        vm.expectRevert(ISwapAndAdd.ZeroAddress.selector);
        this.deployZap(poolManager, permit2, address(0), universalRouter);
    }

    function test_WhenUniversalRouterIsZero() public {
        // it reverts with {ZeroAddress}
        vm.expectRevert(ISwapAndAdd.ZeroAddress.selector);
        this.deployZap(poolManager, permit2, positionManager, address(0));
    }

    modifier givenEveryConstructorArgIsNonZero() {
        _;
    }

    function test_WhenArgsAreNonZero_StoresWiring() public givenEveryConstructorArgIsNonZero {
        // it stores poolManager, permit2, positionManager, and universalRouter
        IZapWiring zap = IZapWiring(this.deployZap(poolManager, permit2, positionManager, universalRouter));
        assertEq(zap.poolManager(), poolManager, "poolManager");
        assertEq(zap.permit2(), permit2, "permit2");
        assertEq(zap.positionManager(), positionManager, "positionManager");
        assertEq(zap.universalRouter(), universalRouter, "universalRouter");
    }
}
