// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {LiquidityAmounts} from "../../contracts/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import {NonfungiblePositionManager} from "../../contracts/NonfungiblePositionManager.sol";
import {LiquidityRange, LiquidityRangeId, LiquidityRangeIdLibrary} from "../../contracts/types/LiquidityRange.sol";

import {Fuzzers} from "@uniswap/v4-core/src/test/Fuzzers.sol";

import {LiquidityOperations} from "../shared/LiquidityOperations.sol";

contract PermitTest is Test, Deployers, GasSnapshot, Fuzzers, LiquidityOperations {
    using FixedPointMathLib for uint256;
    using CurrencyLibrary for Currency;
    using LiquidityRangeIdLibrary for LiquidityRange;
    using PoolIdLibrary for PoolKey;

    PoolId poolId;
    address alice;
    uint256 alicePK;
    address bob;
    uint256 bobPK;

    uint256 constant STARTING_USER_BALANCE = 10_000_000 ether;

    // expresses the fee as a wad (i.e. 3000 = 0.003e18 = 0.30%)
    uint256 FEE_WAD;

    LiquidityRange range;

    function setUp() public {
        (alice, alicePK) = makeAddrAndKey("ALICE");
        (bob, bobPK) = makeAddrAndKey("BOB");

        Deployers.deployFreshManagerAndRouters();
        Deployers.deployMintAndApprove2Currencies();

        (key, poolId) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1, ZERO_BYTES);
        FEE_WAD = uint256(key.fee).mulDivDown(FixedPointMathLib.WAD, 1_000_000);

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

    function test_permit_increaseLiquidity() public {
        uint256 liquidityAlice = 1e18;
        vm.prank(alice);
        _mint(range, liquidityAlice, block.timestamp + 1, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // alice gives bob operator permissions
        _permit(alice, alicePK, tokenIdAlice, bob);

        // bob can increase liquidity on alice's token
        uint256 newLiquidity = 2e18;
        uint256 balance0BobBefore = currency0.balanceOf(bob);
        uint256 balance1BobBefore = currency1.balanceOf(bob);
        vm.prank(bob);
        _increaseLiquidity(range, tokenIdAlice, newLiquidity, ZERO_BYTES, false);

        // alice's position has new liquidity
        (uint256 liquidity,,,,) = lpm.positions(alice, range.toId());
        assertEq(liquidity, liquidityAlice + newLiquidity);

        // bob used his tokens to increase liquidity
        assertGt(balance0BobBefore, currency0.balanceOf(bob));
        assertGt(balance1BobBefore, currency1.balanceOf(bob));
    }

    function test_permit_decreaseLiquidity() public {
        uint256 liquidityAlice = 1e18;
        vm.prank(alice);
        _mint(range, liquidityAlice, block.timestamp + 1, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // alice gives bob operator permissions
        _permit(alice, alicePK, tokenIdAlice, bob);

        // bob can decrease liquidity on alice's token
        uint256 liquidityToRemove = 0.4444e18;
        vm.prank(bob);
        _decreaseLiquidity(range, tokenIdAlice, liquidityToRemove, ZERO_BYTES, false);

        // alice's position decreased liquidity
        (uint256 liquidity,,,,) = lpm.positions(alice, range.toId());
        assertEq(liquidity, liquidityAlice - liquidityToRemove);
    }

    function test_permit_collect() public {
        uint256 liquidityAlice = 1e18;
        vm.prank(alice);
        _mint(range, liquidityAlice, block.timestamp + 1, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // donate to create fee revenue
        uint256 currency0Revenue = 0.4444e18;
        uint256 currency1Revenue = 0.2222e18;
        donateRouter.donate(key, currency0Revenue, currency1Revenue, ZERO_BYTES);

        // alice gives bob operator permissions
        _permit(alice, alicePK, tokenIdAlice, bob);

        // TODO: enable once we fix recipient collection

        // bob collects fees to a recipient
        // address recipient = address(0x00444400);
        // vm.startPrank(bob);
        // _collect(tokenIdAlice, recipient, ZERO_BYTES, false);
        // vm.stopPrank();

        // assertEq(currency0.balanceOf(recipient), currency0Revenue);
        // assertEq(currency1.balanceOf(recipient), currency1Revenue);
    }

    // --- Fail Scenarios --- //
    function test_permit_notOwnerRevert() public {
        // calling permit on a token that is not owned will fail

        uint256 liquidityAlice = 1e18;
        vm.prank(alice);
        _mint(range, liquidityAlice, block.timestamp + 1, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // bob cannot permit himself on alice's token
        bytes32 digest = lpm.getDigest(bob, tokenIdAlice, lpm.nonce(bob), block.timestamp + 1);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPK, digest);

        vm.startPrank(bob);
        vm.expectRevert("Unauthorized");
        lpm.permit(bob, tokenIdAlice, block.timestamp + 1, v, r, s);
        vm.stopPrank();
    }

    function test_noPermit_increaseLiquidityRevert() public {
        // increaseLiquidity fails if the owner did not permit
        uint256 liquidityAlice = 1e18;
        vm.prank(alice);
        _mint(range, liquidityAlice, block.timestamp + 1, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // bob cannot increase liquidity on alice's token
        uint256 newLiquidity = 2e18;
        uint256 balance0BobBefore = currency0.balanceOf(bob);
        uint256 balance1BobBefore = currency1.balanceOf(bob);
        vm.startPrank(bob);
        vm.expectRevert("Not approved");
        _increaseLiquidity(range, tokenIdAlice, newLiquidity, ZERO_BYTES, false);
        vm.stopPrank();
    }

    function test_noPermit_decreaseLiquidityRevert() public {
        // decreaseLiquidity fails if the owner did not permit
        uint256 liquidityAlice = 1e18;
        vm.prank(alice);
        _mint(range, liquidityAlice, block.timestamp + 1, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // bob cannot decrease liquidity on alice's token
        uint256 liquidityToRemove = 0.4444e18;
        vm.startPrank(bob);
        vm.expectRevert("Not approved");
        _decreaseLiquidity(range, tokenIdAlice, liquidityToRemove, ZERO_BYTES, false);
        vm.stopPrank();
    }

    function test_noPermit_collectRevert() public {
        // collect fails if the owner did not permit
        uint256 liquidityAlice = 1e18;
        vm.prank(alice);
        _mint(range, liquidityAlice, block.timestamp + 1, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // donate to create fee revenue
        uint256 currency0Revenue = 0.4444e18;
        uint256 currency1Revenue = 0.2222e18;
        donateRouter.donate(key, currency0Revenue, currency1Revenue, ZERO_BYTES);

        // bob cannot collect fees to a recipient
        address recipient = address(0x00444400);
        vm.startPrank(bob);
        vm.expectRevert("Not approved");
        _collect(range, tokenIdAlice, recipient, ZERO_BYTES, false);
        vm.stopPrank();
    }
}
