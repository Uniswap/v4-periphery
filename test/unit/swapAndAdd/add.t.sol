// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {Vm} from "forge-std/Vm.sol";
import {ISwapAndAdd} from "../../../src/interfaces/ISwapAndAdd.sol";
import {BttBase} from "./BttBase.sol";

contract AddTest is BttBase {
    function test_WhenRecipientIsZero_Reverts() public {
        // it reverts with {InvalidRecipient}
        ISwapAndAdd.AddParams memory p = _addParams(0, 10e18);
        p.recipient = address(0);
        vm.expectRevert(abi.encodeWithSelector(ISwapAndAdd.InvalidRecipient.selector, address(0)));
        zap.add(p);
    }

    function test_WhenRecipientIsZap_Reverts() public {
        // it reverts with {InvalidRecipient}
        ISwapAndAdd.AddParams memory p = _addParams(0, 10e18);
        p.recipient = address(zap);
        vm.expectRevert(abi.encodeWithSelector(ISwapAndAdd.InvalidRecipient.selector, address(zap)));
        zap.add(p);
    }

    function test_WhenDeadlineHasPassed_Reverts() public {
        // it reverts with {DeadlinePassed}
        ISwapAndAdd.AddParams memory p = _addParams(0, 10e18);
        p.deadline = block.timestamp - 1;
        vm.expectRevert(abi.encodeWithSelector(ISwapAndAdd.DeadlinePassed.selector, p.deadline));
        zap.add(p);
    }

    function test_WhenAmount1Only_MintsToRecipient() public {
        // it mints a position NFT to recipient and leaves the zap idle
        uint256 c0Before = currency0.balanceOf(address(this));
        (uint256 tokenId, uint128 liq, uint256 a0, uint256 a1) = zap.add(_addParams(0, 10e18));
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "NFT owner");
        assertGt(liq, 0, "liquidity");
        assertGt(a0, 0, "token0 deployed");
        assertGt(a1, 0, "token1 deployed");
        assertApproxEqAbs(currency0.balanceOf(address(this)), c0Before, 5, "no token0 dust");
        _assertZapIdle();
    }

    function test_WhenAmount0Only_MintsToRecipient() public {
        // it mints a position NFT to recipient and leaves the zap idle
        uint256 c1Before = currency1.balanceOf(address(this));
        (uint256 tokenId, uint128 liq,,) = zap.add(_addParams(10e18, 0));
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "NFT owner");
        assertGt(liq, 0, "liquidity");
        assertApproxEqAbs(currency1.balanceOf(address(this)), c1Before, 5, "no token1 dust");
        _assertZapIdle();
    }

    function test_WhenBothAmountsNonZero_MintsToRecipient() public {
        // it mints a position NFT to recipient and leaves the zap idle
        (uint256 tokenId, uint128 liq,,) = zap.add(_addParams(3e18, 10e18));
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "NFT owner");
        assertGt(liq, 0, "liquidity");
        _assertZapIdle();
    }

    function test_WhenPoolIsNative_MintsAndIdle() public {
        // it mints a native position and leaves the zap idle
        ISwapAndAdd.AddParams memory p = _addParams(1e17, 0);
        p.poolKey = nativeKey;
        (uint256 tokenId, uint128 liq,,) = zap.add{value: 1e17}(p);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "NFT owner");
        assertGt(liq, 0, "liquidity");
        _assertZapIdle();
    }

    function test_WhenAddSucceeds_EmitsAddedMatchingReturns() public {
        // it emits Added whose fields match the return values
        address recipient = makeAddr("recipient");
        ISwapAndAdd.AddParams memory p = _addParams(1e18, 2e18);
        p.recipient = recipient;
        vm.recordLogs();
        (uint256 tokenId, uint128 liq, uint256 a0, uint256 a1) = zap.add(p);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory zapLog;
        uint256 found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(zap)) {
                zapLog = logs[i];
                found++;
            }
        }
        assertEq(found, 1, "exactly one zap event");
        assertEq(zapLog.topics[0], ISwapAndAdd.Added.selector, "topic0");
        assertEq(zapLog.topics[1], bytes32(uint256(uint160(recipient))), "indexed recipient");
        assertEq(zapLog.topics[2], bytes32(tokenId), "indexed tokenId");
        (address caller, uint128 eLiq, uint256 e0, uint256 e1) =
            abi.decode(zapLog.data, (address, uint128, uint256, uint256));
        assertEq(caller, address(this), "caller");
        assertEq(eLiq, liq, "liquidity mirrors return");
        assertEq(e0, a0, "amount0 mirrors return");
        assertEq(e1, a1, "amount1 mirrors return");
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), recipient, "NFT to recipient");
    }
}
