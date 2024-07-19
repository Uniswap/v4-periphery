// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC721Permit} from "../../src/interfaces/IERC721Permit.sol";
import {ERC721Permit} from "../../src/base/ERC721Permit.sol";

import {NonfungiblePositionManager} from "../../src/NonfungiblePositionManager.sol";
import {LiquidityRange} from "../../src/types/LiquidityRange.sol";
import {INonfungiblePositionManager} from "../../src/interfaces/INonfungiblePositionManager.sol";

import {LiquidityOperations} from "../shared/LiquidityOperations.sol";

contract PermitTest is Test, Deployers, LiquidityOperations {
    using FixedPointMathLib for uint256;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    PoolId poolId;
    address alice;
    uint256 alicePK;
    address bob;
    uint256 bobPK;

    uint256 constant STARTING_USER_BALANCE = 10_000_000 ether;

    LiquidityRange range;

    function setUp() public {
        (alice, alicePK) = makeAddrAndKey("ALICE");
        (bob, bobPK) = makeAddrAndKey("BOB");

        Deployers.deployFreshManagerAndRouters();
        Deployers.deployMintAndApprove2Currencies();

        (key, poolId) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1, ZERO_BYTES);

        lpm = new NonfungiblePositionManager(manager);
        IERC20(Currency.unwrap(currency0)).approve(address(lpm), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(lpm), type(uint256).max);

        // Give tokens to Alice and Bob, with approvals
        IERC20(Currency.unwrap(currency0)).transfer(alice, STARTING_USER_BALANCE);
        IERC20(Currency.unwrap(currency1)).transfer(alice, STARTING_USER_BALANCE);
        IERC20(Currency.unwrap(currency0)).transfer(bob, STARTING_USER_BALANCE);
        IERC20(Currency.unwrap(currency1)).transfer(bob, STARTING_USER_BALANCE);
        vm.startPrank(alice);
        IERC20(Currency.unwrap(currency0)).approve(address(lpm), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(lpm), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob);
        IERC20(Currency.unwrap(currency0)).approve(address(lpm), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(lpm), type(uint256).max);
        vm.stopPrank();

        // define a reusable range
        range = LiquidityRange({poolKey: key, tickLower: -300, tickUpper: 300});
    }

    function test_permitTypeHash() public view {
        assertEq(
            IERC721Permit(address(lpm)).PERMIT_TYPEHASH(),
            keccak256("Permit(address spender,uint256 tokenId,uint256 nonce,uint256 deadline)")
        );
    }

    function test_domainTypeHash() public view {
        assertEq(
            ERC721Permit(address(lpm)).EIP712DOMAIN_TYPEHASH(),
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
        );
    }

    function test_permit_increaseLiquidity() public {
        uint256 liquidityAlice = 1e18;
        vm.prank(alice);
        mint(range, liquidityAlice, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // alice gives bob operator permissions
        _permit(alice, alicePK, tokenIdAlice, bob, 1);

        // bob can increase liquidity on alice's token
        uint256 newLiquidity = 2e18;
        uint256 balance0BobBefore = currency0.balanceOf(bob);
        uint256 balance1BobBefore = currency1.balanceOf(bob);
        vm.startPrank(bob);
        increaseLiquidity(tokenIdAlice, newLiquidity, ZERO_BYTES);
        vm.stopPrank();

        // alice's position has new liquidity
        bytes32 positionId =
            keccak256(abi.encodePacked(address(lpm), range.tickLower, range.tickUpper, bytes32(tokenIdAlice)));
        (uint256 liquidity,,) = manager.getPositionInfo(range.poolKey.toId(), positionId);
        assertEq(liquidity, liquidityAlice + newLiquidity);

        // bob used his tokens to increase liquidity
        assertGt(balance0BobBefore, currency0.balanceOf(bob));
        assertGt(balance1BobBefore, currency1.balanceOf(bob));
    }

    function test_permit_decreaseLiquidity() public {
        uint256 liquidityAlice = 1e18;
        vm.prank(alice);
        mint(range, liquidityAlice, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // alice gives bob operator permissions
        _permit(alice, alicePK, tokenIdAlice, bob, 1);

        // bob can decrease liquidity on alice's token
        uint256 liquidityToRemove = 0.4444e18;
        vm.startPrank(bob);
        decreaseLiquidity(tokenIdAlice, liquidityToRemove, ZERO_BYTES);
        vm.stopPrank();

        // alice's position decreased liquidity
        bytes32 positionId =
            keccak256(abi.encodePacked(address(lpm), range.tickLower, range.tickUpper, bytes32(tokenIdAlice)));
        (uint256 liquidity,,) = manager.getPositionInfo(range.poolKey.toId(), positionId);

        assertEq(liquidity, liquidityAlice - liquidityToRemove);
    }

    function test_permit_collect() public {
        uint256 liquidityAlice = 1e18;
        vm.prank(alice);
        mint(range, liquidityAlice, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // donate to create fee revenue
        uint256 currency0Revenue = 0.4444e18;
        uint256 currency1Revenue = 0.2222e18;
        donateRouter.donate(key, currency0Revenue, currency1Revenue, ZERO_BYTES);

        // alice gives bob operator permissions
        _permit(alice, alicePK, tokenIdAlice, bob, 1);

        // TODO: test collection to recipient with a permissioned operator

        // bob collects fees to himself
        address recipient = bob;
        uint256 balance0BobBefore = currency0.balanceOf(bob);
        uint256 balance1BobBefore = currency1.balanceOf(bob);
        vm.startPrank(bob);
        collect(tokenIdAlice, recipient, ZERO_BYTES);
        vm.stopPrank();

        assertApproxEqAbs(currency0.balanceOf(recipient), balance0BobBefore + currency0Revenue, 1 wei);
        assertApproxEqAbs(currency1.balanceOf(recipient), balance1BobBefore + currency1Revenue, 1 wei);
    }

    // --- Fail Scenarios --- //
    function test_permit_notOwnerRevert() public {
        // calling permit on a token that is not owned will fail

        uint256 liquidityAlice = 1e18;
        vm.prank(alice);
        mint(range, liquidityAlice, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // bob cannot permit himself on alice's token
        bytes32 digest = lpm.getDigest(bob, tokenIdAlice, 0, block.timestamp + 1);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPK, digest);

        vm.startPrank(bob);
        vm.expectRevert(IERC721Permit.Unauthorized.selector);
        lpm.permit(bob, tokenIdAlice, block.timestamp + 1, 0, v, r, s);
        vm.stopPrank();
    }

    function test_noPermit_increaseLiquidityRevert() public {
        // increaseLiquidity fails if the owner did not permit
        uint256 liquidityAlice = 1e18;
        vm.prank(alice);
        mint(range, liquidityAlice, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // bob cannot increase liquidity on alice's token
        uint256 newLiquidity = 2e18;
        bytes memory increase = LiquidityOperations.getIncreaseEncoded(tokenIdAlice, newLiquidity, ZERO_BYTES);
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(INonfungiblePositionManager.NotApproved.selector, address(bob)));
        lpm.modifyLiquidities(increase, _deadline);
        vm.stopPrank();
    }

    function test_noPermit_decreaseLiquidityRevert() public {
        // decreaseLiquidity fails if the owner did not permit
        uint256 liquidityAlice = 1e18;
        vm.prank(alice);
        mint(range, liquidityAlice, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // bob cannot decrease liquidity on alice's token
        uint256 liquidityToRemove = 0.4444e18;
        bytes memory decrease = LiquidityOperations.getDecreaseEncoded(tokenIdAlice, liquidityToRemove, ZERO_BYTES);
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(INonfungiblePositionManager.NotApproved.selector, address(bob)));
        lpm.modifyLiquidities(decrease, _deadline);
        vm.stopPrank();
    }

    function test_noPermit_collectRevert() public {
        // collect fails if the owner did not permit
        uint256 liquidityAlice = 1e18;
        vm.prank(alice);
        mint(range, liquidityAlice, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // donate to create fee revenue
        uint256 currency0Revenue = 0.4444e18;
        uint256 currency1Revenue = 0.2222e18;
        donateRouter.donate(key, currency0Revenue, currency1Revenue, ZERO_BYTES);

        // bob cannot collect fees to a recipient
        address recipient = address(0x00444400);
        bytes memory collect = LiquidityOperations.getCollectEncoded(tokenIdAlice, recipient, ZERO_BYTES);
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(INonfungiblePositionManager.NotApproved.selector, address(bob)));
        lpm.modifyLiquidities(collect, block.timestamp + 1);
        vm.stopPrank();
    }

    function test_permit_nonceAlreadyUsed() public {
        uint256 liquidityAlice = 1e18;
        vm.prank(alice);
        mint(range, liquidityAlice, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // alice gives bob operator permissions
        uint256 nonce = 1;
        _permit(alice, alicePK, tokenIdAlice, bob, nonce);

        // alice cannot reuse the nonce
        bytes32 digest = lpm.getDigest(bob, tokenIdAlice, nonce, block.timestamp + 1);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);

        vm.startPrank(alice);
        vm.expectRevert(IERC721Permit.NonceAlreadyUsed.selector);
        lpm.permit(bob, tokenIdAlice, block.timestamp + 1, nonce, v, r, s);
        vm.stopPrank();
    }

    function test_permit_nonceAlreadyUsed_twoPositions() public {
        uint256 liquidityAlice = 1e18;
        vm.prank(alice);
        mint(range, liquidityAlice, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        vm.prank(alice);
        range.tickLower = -600;
        range.tickUpper = 600;
        mint(range, liquidityAlice, alice, ZERO_BYTES);
        uint256 tokenIdAlice2 = lpm.nextTokenId() - 1;

        // alice gives bob operator permissions for first token
        uint256 nonce = 1;
        _permit(alice, alicePK, tokenIdAlice, bob, nonce);

        // alice cannot reuse the nonce for the second token
        bytes32 digest = lpm.getDigest(bob, tokenIdAlice2, nonce, block.timestamp + 1);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);

        vm.startPrank(alice);
        vm.expectRevert(IERC721Permit.NonceAlreadyUsed.selector);
        lpm.permit(bob, tokenIdAlice2, block.timestamp + 1, nonce, v, r, s);
        vm.stopPrank();
    }

    // Bob can use alice's signature to permit & decrease liquidity
    function test_permit_operatorSelfPermit() public {
        uint256 liquidityAlice = 1e18;
        vm.startPrank(alice);
        mint(range, liquidityAlice, alice, ZERO_BYTES);
        vm.stopPrank();
        uint256 tokenId = lpm.nextTokenId() - 1;

        // Alice gives Bob permission to operate on her liquidity
        uint256 nonce = 1;
        bytes32 digest = lpm.getDigest(bob, tokenId, nonce, block.timestamp + 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);

        // bob gives himself permission
        vm.prank(bob);
        lpm.permit(bob, tokenId, block.timestamp + 1, nonce, v, r, s);

        // bob can decrease liquidity on alice's token
        uint256 liquidityToRemove = 0.4444e18;
        vm.startPrank(bob);
        decreaseLiquidity(tokenId, liquidityToRemove, ZERO_BYTES);
        vm.stopPrank();

        bytes32 positionId =
            keccak256(abi.encodePacked(address(lpm), range.tickLower, range.tickUpper, bytes32(tokenId)));
        (uint256 liquidity,,) = manager.getPositionInfo(range.poolKey.toId(), positionId);
        assertEq(liquidity, liquidityAlice - liquidityToRemove);
    }

    // Charlie uses Alice's signature to give permission to Bob
    function test_permit_thirdParty() public {
        uint256 liquidityAlice = 1e18;
        vm.startPrank(alice);
        mint(range, liquidityAlice, alice, ZERO_BYTES);
        vm.stopPrank();
        uint256 tokenId = lpm.nextTokenId() - 1;

        // Alice gives Bob permission to operate on her liquidity
        uint256 nonce = 1;
        bytes32 digest = lpm.getDigest(bob, tokenId, nonce, block.timestamp + 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);

        // charlie gives Bob permission to operate on alice's token
        address charlie = makeAddr("CHARLIE");
        vm.prank(charlie);
        lpm.permit(bob, tokenId, block.timestamp + 1, nonce, v, r, s);

        // bob can decrease liquidity on alice's token
        uint256 liquidityToRemove = 0.4444e18;
        vm.startPrank(bob);
        decreaseLiquidity(tokenId, liquidityToRemove, ZERO_BYTES);
        vm.stopPrank();

        bytes32 positionId =
            keccak256(abi.encodePacked(address(lpm), range.tickLower, range.tickUpper, bytes32(tokenId)));
        (uint256 liquidity,,) = manager.getPositionInfo(range.poolKey.toId(), positionId);
        assertEq(liquidity, liquidityAlice - liquidityToRemove);
    }
}
