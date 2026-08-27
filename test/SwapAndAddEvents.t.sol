// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {ISwapAndAdd} from "../src/interfaces/ISwapAndAdd.sol";
import {IUniversalRouter} from "../src/interfaces/external/IUniversalRouter.sol";
import {PositionConfig} from "./shared/PositionConfig.sol";
import {PosmTestSetup} from "./shared/PosmTestSetup.sol";

/// @notice Each operation emits exactly one event whose fields mirror its return values.
contract SwapAndAddEventsTest is PosmTestSetup {
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    ISwapAndAdd zap;
    address recipient = makeAddr("recipient");

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        deployAndApprovePosm(manager);

        (key,) = initPool(currency0, currency1, IHooks(address(0)), 3000, int24(60), SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -600_000, tickUpper: 600_000, liquidityDelta: int256(1e24), salt: 0}),
            ""
        );

        zap = ISwapAndAdd(
            deployCode("SwapAndAdd.sol:SwapAndAdd", abi.encode(manager, permit2, lpm, IUniversalRouter(makeAddr("ur"))))
        );
        permit2.approve(Currency.unwrap(currency0), address(zap), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(zap), type(uint160).max, type(uint48).max);
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
    }

    // ------------------------------- helpers -------------------------------

    function _addParams(uint256 a0, uint256 a1) internal view returns (ISwapAndAdd.AddParams memory) {
        return ISwapAndAdd.AddParams({
            poolKey: key,
            tickLower: -600,
            tickUpper: 600,
            amount0In: a0,
            amount1In: a1,
            route: "",
            routeFunding: new ISwapAndAdd.TokenAmount[](0),
            minLiquidity: 1,
            recipient: recipient,
            hookData: "",
            deadline: block.timestamp + 1
        });
    }

    /// @dev Returns the single log that the zap emitted.
    function _zapLog() internal returns (Vm.Log memory) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found = type(uint256).max;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(zap)) {
                assertEq(found, type(uint256).max, "exactly one zap event per operation");
                found = i;
            }
        }
        assertTrue(found != type(uint256).max, "the operation must emit a zap event");
        return logs[found];
    }

    function _mintWithFees(address owner) internal returns (uint256 tokenId) {
        tokenId = lpm.nextTokenId();
        mint(PositionConfig({poolKey: key, tickLower: -600, tickUpper: 600}), 1e21, owner, "");
        swap(key, true, -int256(1e20), "");
        swap(key, false, -int256(1e20), "");
    }

    // ------------------------------- pins -------------------------------

    function test_add_emitsAdded_mirroringReturns() public {
        vm.recordLogs();
        (uint256 tokenId, uint128 liquidity, uint256 a0, uint256 a1) = zap.add(_addParams(1e18, 2e18));

        Vm.Log memory log = _zapLog();
        assertEq(log.topics[0], ISwapAndAdd.Added.selector, "topic0");
        assertEq(log.topics[1], bytes32(uint256(uint160(recipient))), "indexed recipient");
        assertEq(log.topics[2], bytes32(tokenId), "indexed tokenId");
        (address caller, uint128 eLiq, uint256 e0, uint256 e1) =
            abi.decode(log.data, (address, uint128, uint256, uint256));
        assertEq(caller, address(this), "caller");
        assertEq(eLiq, liquidity, "liquidity mirrors return");
        assertEq(e0, a0, "amount0 mirrors return");
        assertEq(e1, a1, "amount1 mirrors return");
    }

    function test_rebalance_emitsRebalanced_withLineage() public {
        uint256 oldId = _mintWithFees(address(this));

        vm.recordLogs();
        (uint256 newId, uint128 liquidity, uint256 a0, uint256 a1) = zap.rebalance(
            ISwapAndAdd.RebalanceParams({
                tokenId: oldId,
                additional0: 0,
                additional1: 0,
                newTickLower: -1200,
                newTickUpper: 1200,
                route: "",
                routeFunding: new ISwapAndAdd.TokenAmount[](0),
                minLiquidity: 1,
                recipient: recipient,
                hookData: "",
                deadline: block.timestamp + 1
            })
        );

        Vm.Log memory log = _zapLog();
        assertEq(log.topics[0], ISwapAndAdd.Rebalanced.selector, "topic0");
        assertEq(log.topics[1], bytes32(uint256(uint160(recipient))), "indexed recipient");
        assertEq(log.topics[2], bytes32(oldId), "indexed oldTokenId (lineage)");
        assertEq(log.topics[3], bytes32(newId), "indexed newTokenId (lineage)");
        (address caller, uint128 eLiq, uint256 e0, uint256 e1) =
            abi.decode(log.data, (address, uint128, uint256, uint256));
        assertEq(caller, address(this), "caller");
        assertEq(eLiq, liquidity, "liquidity mirrors return");
        assertEq(e0, a0, "amount0 mirrors return");
        assertEq(e1, a1, "amount1 mirrors return");
    }

    function test_increase_emitsIncreased_withResolvedRecipient() public {
        uint256 tokenId = _mintWithFees(address(this));

        vm.recordLogs();
        (uint128 added, uint256 a0, uint256 a1) = zap.increase(
            ISwapAndAdd.IncreaseParams({
                tokenId: tokenId,
                amount0In: 1e18,
                amount1In: 1e18,
                route: "",
                routeFunding: new ISwapAndAdd.TokenAmount[](0),
                minLiquidityAdded: 1,
                recipient: recipient,
                hookData: "",
                deadline: block.timestamp + 1
            })
        );

        Vm.Log memory log = _zapLog();
        assertEq(log.topics[0], ISwapAndAdd.Increased.selector, "topic0");
        assertEq(log.topics[1], bytes32(uint256(uint160(recipient))), "indexed resolved recipient");
        assertEq(log.topics[2], bytes32(tokenId), "indexed tokenId");
        (address caller, uint128 eLiq, uint256 e0, uint256 e1) =
            abi.decode(log.data, (address, uint128, uint256, uint256));
        assertEq(caller, address(this), "caller");
        assertEq(eLiq, added, "liquidityAdded mirrors return");
        assertEq(e0, a0, "amount0 mirrors return");
        assertEq(e1, a1, "amount1 mirrors return");
    }

    function test_compound_emitsCompounded() public {
        uint256 tokenId = _mintWithFees(address(this));

        vm.recordLogs();
        (uint128 added, uint256 a0, uint256 a1) = zap.compound(
            ISwapAndAdd.CompoundParams({
                tokenId: tokenId,
                route: "",
                minLiquidityAdded: 1,
                recipient: recipient,
                hookData: "",
                deadline: block.timestamp + 1
            })
        );

        Vm.Log memory log = _zapLog();
        assertEq(log.topics[0], ISwapAndAdd.Compounded.selector, "topic0");
        assertEq(log.topics[1], bytes32(uint256(uint160(recipient))), "indexed resolved recipient");
        assertEq(log.topics[2], bytes32(tokenId), "indexed tokenId");
        (address caller, uint128 eLiq, uint256 e0, uint256 e1) =
            abi.decode(log.data, (address, uint128, uint256, uint256));
        assertEq(caller, address(this), "caller");
        assertEq(eLiq, added, "liquidityAdded mirrors return");
        assertEq(e0, a0, "amount0 mirrors return");
        assertEq(e1, a1, "amount1 mirrors return");
    }

    /// @dev For an operator, the event carries the owner as the recipient.
    function test_increase_byOperator_eventCarriesOwnerAsRecipient() public {
        uint256 tokenId = _mintWithFees(address(this));
        address operator = makeAddr("operator");
        IERC721(address(lpm)).setApprovalForAll(operator, true);
        seedBalance(operator);
        vm.startPrank(operator);
        MockERC20Ish(Currency.unwrap(currency0)).approve(address(permit2), type(uint256).max);
        MockERC20Ish(Currency.unwrap(currency1)).approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(currency0), address(zap), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(zap), type(uint160).max, type(uint48).max);

        vm.recordLogs();
        zap.increase(
            ISwapAndAdd.IncreaseParams({
                tokenId: tokenId,
                amount0In: 1e18,
                amount1In: 1e18,
                route: "",
                routeFunding: new ISwapAndAdd.TokenAmount[](0),
                minLiquidityAdded: 1,
                recipient: operator, // ignored, resolved to the owner
                hookData: "",
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        Vm.Log memory log = _zapLog();
        assertEq(log.topics[1], bytes32(uint256(uint160(address(this)))), "recipient resolved to the OWNER");
        (address caller,,,) = abi.decode(log.data, (address, uint128, uint256, uint256));
        assertEq(caller, operator, "caller is the operator");
    }
}

interface MockERC20Ish {
    function approve(address, uint256) external returns (bool);
}
