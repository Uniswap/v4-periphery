// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";

import {IPositionManager, IPoolInitializer_v4} from "../../src/interfaces/IPositionManager.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {PositionConfig} from "../shared/PositionConfig.sol";
import {IMulticall_v4} from "../../src/interfaces/IMulticall_v4.sol";
import {LiquidityFuzzers} from "../shared/fuzz/LiquidityFuzzers.sol";
import {Planner, Plan} from "../shared/Planner.sol";
import {PosmTestSetup} from "../shared/PosmTestSetup.sol";
import {Permit2SignatureHelpers} from "../shared/Permit2SignatureHelpers.sol";
import {Permit2Forwarder, IPermit2Forwarder} from "../../src/base/Permit2Forwarder.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";
import {IERC721Permit_v4} from "../../src/interfaces/IERC721Permit_v4.sol";

contract PositionManagerMulticallTest is Test, Permit2SignatureHelpers, PosmTestSetup, LiquidityFuzzers {
    using FixedPointMathLib for uint256;
    using StateLibrary for IPoolManager;
    using StateLibrary for IPoolManager;

    PoolId poolId;
    address alice;
    uint256 alicePK;
    address bob;
    // bob used for permit2 signature tests
    uint256 bobPK;
    address charlie; // charlie will NOT approve posm in setup()
    uint256 charliePK;

    Permit2Forwarder permit2Forwarder;

    uint160 permitAmount = type(uint160).max;
    // the expiration of the allowance is large
    uint48 permitExpiration = uint48(block.timestamp + 10e18);
    uint48 permitNonce = 0;

    // redefine error from permit2/src/PermitErrors.sol since its hard-pinned to a solidity version
    error InvalidNonce();

    bytes32 PERMIT2_DOMAIN_SEPARATOR;

    PositionConfig config;

    function setUp() public {
        (alice, alicePK) = makeAddrAndKey("ALICE");
        (bob, bobPK) = makeAddrAndKey("BOB");
        (charlie, charliePK) = makeAddrAndKey("CHARLIE");

        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        (key, poolId) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);

        // Requires currency0 and currency1 to be set in base Deployers contract.
        deployAndApprovePosm(manager);

        permit2Forwarder = new Permit2Forwarder(permit2);
        PERMIT2_DOMAIN_SEPARATOR = permit2.DOMAIN_SEPARATOR();

        seedBalance(alice);
        approvePosmFor(alice);

        seedBalance(bob);
        approvePosmFor(bob);

        // do not approve posm for charlie, but approve permit2 for allowance transfer
        seedBalance(charlie);
        vm.startPrank(charlie);
        IERC20(Currency.unwrap(currency0)).approve(address(permit2), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(permit2), type(uint256).max);
        vm.stopPrank();
    }

    function test_multicall_initializePool_mint() public {
        key = PoolKey({currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 10, hooks: IHooks(address(0))});

        // Use multicall to initialize a pool and mint liquidity
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(IPoolInitializer_v4.initializePool.selector, key, SQRT_PRICE_1_1);

        config = PositionConfig({
            poolKey: key,
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing)
        });

        Plan memory planner = Planner.init();
        planner.add(
            Actions.MINT_POSITION,
            abi.encode(
                config.poolKey,
                config.tickLower,
                config.tickUpper,
                100e18,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );
        bytes memory actions = planner.finalizeModifyLiquidityWithClose(config.poolKey);

        calls[1] = abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector, actions, _deadline);

        IMulticall_v4(address(lpm)).multicall(calls);

        // test swap, doesn't revert, showing the pool was initialized
        int256 amountSpecified = -1e18;
        BalanceDelta result = swap(key, true, amountSpecified, ZERO_BYTES);
        assertEq(result.amount0(), amountSpecified);
        assertGt(result.amount1(), 0);
    }

    function test_multicall_initializePool_twice_andMint_succeeds() public {
        key = PoolKey({currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 10, hooks: IHooks(address(0))});
        manager.initialize(key, SQRT_PRICE_1_1);

        // Use multicall to initialize the pool again.
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(IPoolInitializer_v4.initializePool.selector, key, SQRT_PRICE_1_1);

        config = PositionConfig({
            poolKey: key,
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing)
        });

        Plan memory planner = Planner.init();
        planner.add(
            Actions.MINT_POSITION,
            abi.encode(
                config.poolKey,
                config.tickLower,
                config.tickUpper,
                100e18,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );
        bytes memory actions = planner.finalizeModifyLiquidityWithClose(config.poolKey);

        calls[1] = abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector, actions, _deadline);

        IMulticall_v4(address(lpm)).multicall(calls);

        // test swap, doesn't revert, showing the mint succeeded even after initialize reverted
        int256 amountSpecified = -1e18;
        BalanceDelta result = swap(key, true, amountSpecified, ZERO_BYTES);
        assertEq(result.amount0(), amountSpecified);
        assertGt(result.amount1(), 0);
    }

    function test_multicall_initializePool_mint_native() public {
        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: currency1,
            fee: 0,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });

        // Use multicall to initialize a pool and mint liquidity
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(IPoolInitializer_v4.initializePool.selector, key, SQRT_PRICE_1_1);

        config = PositionConfig({
            poolKey: key,
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing)
        });

        Plan memory planner = Planner.init();
        planner.add(
            Actions.MINT_POSITION,
            abi.encode(
                config, 100e18, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ActionConstants.MSG_SENDER, ZERO_BYTES
            )
        );
        bytes memory actions = planner.finalizeModifyLiquidityWithClose(config.poolKey);

        calls[1] = abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector, actions, _deadline);

        IMulticall_v4(address(lpm)).multicall{value: 1000 ether}(calls);

        // test swap, doesn't revert, showing the pool was initialized
        int256 amountSpecified = -1e18;
        BalanceDelta result = swap(key, true, amountSpecified, ZERO_BYTES);
        assertEq(result.amount0(), amountSpecified);
        assertGt(result.amount1(), 0);
    }

    // charlie will attempt to decrease liquidity without approval
    // posm's NotApproved(charlie) should bubble up through Multicall
    function test_multicall_bubbleRevert() public {
        config = PositionConfig({
            poolKey: key,
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing)
        });
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, address(this), ZERO_BYTES);

        Plan memory planner = Planner.init();
        planner.add(
            Actions.DECREASE_LIQUIDITY,
            abi.encode(tokenId, 100e18, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
        );
        bytes memory actions = planner.finalizeModifyLiquidityWithClose(config.poolKey);

        // Use multicall to decrease liquidity
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector, actions, _deadline);

        vm.startPrank(charlie);
        vm.expectRevert(abi.encodeWithSelector(IPositionManager.NotApproved.selector, charlie));
        lpm.multicall(calls);
        vm.stopPrank();
    }

    // decrease liquidity but forget to close
    // core's CurrencyNotSettled should bubble up through Multicall
    function test_multicall_bubbleRevert_core() public {
        config = PositionConfig({
            poolKey: key,
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing)
        });
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, address(this), ZERO_BYTES);

        // do not close deltas to throw CurrencyNotSettled in core
        Plan memory planner = Planner.init();
        planner.add(
            Actions.DECREASE_LIQUIDITY,
            abi.encode(tokenId, 100e18, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
        );
        bytes memory actions = planner.encode();

        // Use multicall to decrease liquidity
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector, actions, _deadline);

        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        lpm.multicall(calls);
    }

    function test_multicall_permitAndDecrease() public {
        config = PositionConfig({poolKey: key, tickLower: -60, tickUpper: 60});
        uint256 liquidityAlice = 1e18;
        vm.startPrank(alice);
        uint256 tokenId = lpm.nextTokenId();
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        vm.stopPrank();

        // Alice gives Bob permission to operate on her liquidity
        uint256 nonce = 1;
        bytes32 digest = getDigest(bob, tokenId, nonce, block.timestamp + 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // bob gives himself permission and decreases liquidity
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(
            IERC721Permit_v4(lpm).permit.selector, bob, tokenId, block.timestamp + 1, nonce, signature
        );
        uint256 liquidityToRemove = 0.4444e18;
        bytes memory actions = getDecreaseEncoded(tokenId, config, liquidityToRemove, ZERO_BYTES);
        calls[1] = abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector, actions, _deadline);

        vm.prank(bob);
        lpm.multicall(calls);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);
        assertEq(liquidity, liquidityAlice - liquidityToRemove);
    }

    function test_multicall_permit_mint() public {
        config = PositionConfig({
            poolKey: key,
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing)
        });
        // 1. revoke the auto permit we give to posm for 1 token
        vm.prank(bob);
        permit2.approve(Currency.unwrap(currency0), address(lpm), 0, 0);

        (uint160 _amount,, uint48 _expiration) =
            permit2.allowance(address(bob), Currency.unwrap(currency0), address(this));

        assertEq(_amount, 0);
        assertEq(_expiration, 0);

        uint256 tokenId = lpm.nextTokenId();
        bytes memory mintCall = getMintEncoded(config, 10e18, bob, ZERO_BYTES);

        // 2 . call a mint that reverts because position manager doesn't have permission on permit2
        vm.expectRevert(abi.encodeWithSelector(IAllowanceTransfer.InsufficientAllowance.selector, 0));
        vm.prank(bob);
        lpm.modifyLiquidities(mintCall, _deadline);

        // 3. encode a permit for that revoked token
        IAllowanceTransfer.PermitSingle memory permit =
            defaultERC20PermitAllowance(Currency.unwrap(currency0), permitAmount, permitExpiration, permitNonce);
        permit.spender = address(lpm);
        bytes memory sig = getPermitSignature(permit, bobPK, PERMIT2_DOMAIN_SEPARATOR);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(Permit2Forwarder.permit.selector, bob, permit, sig);
        calls[1] = abi.encodeWithSelector(lpm.modifyLiquidities.selector, mintCall, _deadline);

        vm.prank(bob);
        lpm.multicall(calls);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        (_amount,,) = permit2.allowance(address(bob), Currency.unwrap(currency0), address(lpm));

        assertEq(_amount, permitAmount);
        assertEq(liquidity, 10e18);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), bob);
    }

    function test_multicall_permit_batch_mint() public {
        config = PositionConfig({
            poolKey: key,
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing)
        });
        // 1. revoke the auto permit we give to posm for 1 token
        vm.prank(bob);
        permit2.approve(Currency.unwrap(currency0), address(lpm), 0, 0);
        permit2.approve(Currency.unwrap(currency1), address(lpm), 0, 0);

        (uint160 _amount0,, uint48 _expiration0) =
            permit2.allowance(address(bob), Currency.unwrap(currency0), address(this));

        (uint160 _amount1,, uint48 _expiration1) =
            permit2.allowance(address(bob), Currency.unwrap(currency1), address(this));

        assertEq(_amount0, 0);
        assertEq(_expiration0, 0);
        assertEq(_amount1, 0);
        assertEq(_expiration1, 0);

        uint256 tokenId = lpm.nextTokenId();
        bytes memory mintCall = getMintEncoded(config, 10e18, bob, ZERO_BYTES);

        // 2 . call a mint that reverts because position manager doesn't have permission on permit2
        vm.expectRevert(abi.encodeWithSelector(IAllowanceTransfer.InsufficientAllowance.selector, 0));
        vm.prank(bob);
        lpm.modifyLiquidities(mintCall, _deadline);

        // 3. encode a permit for that revoked token
        address[] memory tokens = new address[](2);
        tokens[0] = Currency.unwrap(currency0);
        tokens[1] = Currency.unwrap(currency1);

        IAllowanceTransfer.PermitBatch memory permit =
            defaultERC20PermitBatchAllowance(tokens, permitAmount, permitExpiration, permitNonce);
        permit.spender = address(lpm);
        bytes memory sig = getPermitBatchSignature(permit, bobPK, PERMIT2_DOMAIN_SEPARATOR);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(Permit2Forwarder.permitBatch.selector, bob, permit, sig);
        calls[1] = abi.encodeWithSelector(lpm.modifyLiquidities.selector, mintCall, _deadline);

        vm.prank(bob);
        lpm.multicall(calls);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        (_amount0,,) = permit2.allowance(address(bob), Currency.unwrap(currency0), address(lpm));
        (_amount1,,) = permit2.allowance(address(bob), Currency.unwrap(currency1), address(lpm));
        assertEq(_amount0, permitAmount);
        assertEq(_amount1, permitAmount);
        assertEq(liquidity, 10e18);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), bob);
    }

    /// @notice test that a front-ran permit does not fail a multicall with permit
    function test_multicall_permit_frontrun_suceeds() public {
        config = PositionConfig({
            poolKey: key,
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing)
        });

        // Charlie signs permit for the two tokens
        IAllowanceTransfer.PermitSingle memory permit0 =
            defaultERC20PermitAllowance(Currency.unwrap(currency0), permitAmount, permitExpiration, permitNonce);
        permit0.spender = address(lpm);
        bytes memory sig0 = getPermitSignature(permit0, charliePK, PERMIT2_DOMAIN_SEPARATOR);

        IAllowanceTransfer.PermitSingle memory permit1 =
            defaultERC20PermitAllowance(Currency.unwrap(currency1), permitAmount, permitExpiration, permitNonce);
        permit1.spender = address(lpm);
        bytes memory sig1 = getPermitSignature(permit1, charliePK, PERMIT2_DOMAIN_SEPARATOR);

        // bob front-runs the permits
        vm.startPrank(bob);
        lpm.permit(charlie, permit0, sig0);
        lpm.permit(charlie, permit1, sig1);
        vm.stopPrank();

        // bob's front-run was successful
        (uint160 _amount, uint48 _expiration, uint48 _nonce) =
            permit2.allowance(charlie, Currency.unwrap(currency0), address(lpm));
        assertEq(_amount, permitAmount);
        assertEq(_expiration, permitExpiration);
        assertEq(_nonce, permitNonce + 1);
        (uint160 _amount1, uint48 _expiration1, uint48 _nonce1) =
            permit2.allowance(charlie, Currency.unwrap(currency1), address(lpm));
        assertEq(_amount1, permitAmount);
        assertEq(_expiration1, permitExpiration);
        assertEq(_nonce1, permitNonce + 1);

        // charlie tries to mint an LP token with multicall(permit, permit, mint)
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeWithSelector(IPermit2Forwarder.permit.selector, charlie, permit0, sig0);
        calls[1] = abi.encodeWithSelector(IPermit2Forwarder.permit.selector, charlie, permit1, sig1);
        bytes memory mintCall = getMintEncoded(config, 10e18, charlie, ZERO_BYTES);
        calls[2] = abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector, mintCall, _deadline);

        uint256 tokenId = lpm.nextTokenId();
        vm.expectRevert();
        IERC721(address(lpm)).ownerOf(tokenId); // token does not exist

        bytes[] memory results = lpm.multicall(calls);
        assertEq(results[0], abi.encode(abi.encodeWithSelector(InvalidNonce.selector)));
        assertEq(results[1], abi.encode(abi.encodeWithSelector(InvalidNonce.selector)));

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), charlie);
    }

    /// @notice test that a front-ran permitBatch does not fail a multicall with permitBatch
    function test_multicall_permitBatch_frontrun_suceeds() public {
        config = PositionConfig({
            poolKey: key,
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing)
        });

        // Charlie signs permitBatch for the two tokens
        address[] memory tokens = new address[](2);
        tokens[0] = Currency.unwrap(currency0);
        tokens[1] = Currency.unwrap(currency1);

        IAllowanceTransfer.PermitBatch memory permit =
            defaultERC20PermitBatchAllowance(tokens, permitAmount, permitExpiration, permitNonce);
        permit.spender = address(lpm);
        bytes memory sig = getPermitBatchSignature(permit, charliePK, PERMIT2_DOMAIN_SEPARATOR);

        // bob front-runs the permits
        vm.prank(bob);
        lpm.permitBatch(charlie, permit, sig);

        // bob's front-run was successful
        (uint160 _amount, uint48 _expiration, uint48 _nonce) =
            permit2.allowance(charlie, Currency.unwrap(currency0), address(lpm));
        assertEq(_amount, permitAmount);
        assertEq(_expiration, permitExpiration);
        assertEq(_nonce, permitNonce + 1);
        (uint160 _amount1, uint48 _expiration1, uint48 _nonce1) =
            permit2.allowance(charlie, Currency.unwrap(currency1), address(lpm));
        assertEq(_amount1, permitAmount);
        assertEq(_expiration1, permitExpiration);
        assertEq(_nonce1, permitNonce + 1);

        // charlie tries to mint an LP token with multicall(permitBatch, mint)
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(lpm.permitBatch.selector, charlie, permit, sig);
        bytes memory mintCall = getMintEncoded(config, 10e18, charlie, ZERO_BYTES);
        calls[1] = abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector, mintCall, _deadline);

        uint256 tokenId = lpm.nextTokenId();
        vm.expectRevert();
        IERC721(address(lpm)).ownerOf(tokenId); // token does not exist

        bytes[] memory results = lpm.multicall(calls);
        assertEq(results[0], abi.encode(abi.encodeWithSelector(InvalidNonce.selector)));

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), charlie);
    }
}
