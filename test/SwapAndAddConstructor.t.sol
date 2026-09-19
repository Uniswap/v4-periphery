// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ISwapAndAdd} from "../src/interfaces/ISwapAndAdd.sol";

interface IZapWiring {
    function poolManager() external view returns (address);
    function permit2() external view returns (address);
    function positionManager() external view returns (address);
    function universalRouter() external view returns (address);
}

/// @notice Constructor wiring tests. The constructor zero-checks and stores all four addresses.
contract SwapAndAddConstructorTest is Test {
    address pm = makeAddr("poolManager");
    address p2 = makeAddr("permit2");
    address posm = makeAddr("positionManager");
    address ur = makeAddr("universalRouter");

    /// @dev Raw create bubbles the creation revert, which deployCode swallows. External so that vm.expectRevert observes it.
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

    function test_constructor_storesWiring() public {
        IZapWiring zap = IZapWiring(this.deployZap(pm, p2, posm, ur));
        assertEq(zap.poolManager(), pm, "poolManager stored");
        assertEq(zap.permit2(), p2, "permit2 stored");
        assertEq(zap.positionManager(), posm, "positionManager stored");
        assertEq(zap.universalRouter(), ur, "universalRouter stored");
    }

    function test_constructor_zeroPoolManager_reverts() public {
        vm.expectRevert(ISwapAndAdd.ZeroAddress.selector);
        this.deployZap(address(0), p2, posm, ur);
    }

    function test_constructor_zeroPermit2_reverts() public {
        vm.expectRevert(ISwapAndAdd.ZeroAddress.selector);
        this.deployZap(pm, address(0), posm, ur);
    }

    function test_constructor_zeroPositionManager_reverts() public {
        vm.expectRevert(ISwapAndAdd.ZeroAddress.selector);
        this.deployZap(pm, p2, address(0), ur);
    }

    function test_constructor_zeroUniversalRouter_reverts() public {
        vm.expectRevert(ISwapAndAdd.ZeroAddress.selector);
        this.deployZap(pm, p2, posm, address(0));
    }
}
