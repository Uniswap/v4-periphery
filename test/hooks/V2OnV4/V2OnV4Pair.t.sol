// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IUniswapV2Factory} from "briefcase/protocols/v2-core/interfaces/IUniswapV2Factory.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IV2OnV4Pair} from "../../../src/interfaces/IV2OnV4Pair.sol";
import {IUniswapV2Pair} from "briefcase/protocols/v2-core/interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Callee} from "briefcase/protocols/v2-core/interfaces/IUniswapV2Callee.sol";
import {MockClaimManager} from "../../mocks/MockClaimManager.sol";

contract V2OnV4PairTest is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using FixedPointMathLib for uint256;

    // Test contracts
    IUniswapV2Factory public factory;
    IV2OnV4Pair public pair;
    MockClaimManager public claimManager;

    // Tokens
    MockERC20 public token0;
    MockERC20 public token1;
    MockERC20 public token2;

    // Pool configuration
    PoolKey public poolKey;
    PoolId public poolId;

    // Test users
    address public alice;
    address public feeRecipient;

    // Constants
    uint256 constant INIT_TOKEN_BALANCE = 1000 ether;
    uint256 constant MINIMUM_LIQUIDITY = 1000;
    uint160 constant INIT_SQRT_PRICE = 79228162514264337593543950336; // 1:1 price

    // Events to test
    function setUp() public {
        // Deploy V4 core contracts
        deployFreshManagerAndRouters();
        claimManager = new MockClaimManager(manager);

        // Set up test users
        alice = makeAddr("alice");
        feeRecipient = makeAddr("feeRecipient");

        // Deploy tokens
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        token2 = new MockERC20("Token2", "TK2", 18);

        // Sort tokens for consistent ordering
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        factory = IUniswapV2Factory(
            payable(
                address(
                    uint160(
                        type(uint160).max & clearAllHookPermissionsMask | Hooks.BEFORE_SWAP_FLAG
                            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                            | Hooks.BEFORE_INITIALIZE_FLAG
                    )
                )
            )
        );

        deployCodeTo("V2OnV4FactoryHook", abi.encode(manager), address(factory));

        // Create pool key
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 1,
            hooks: IHooks(address(factory))
        });
        poolId = poolKey.toId();

        // Initialize the pool (this will create the pair)
        manager.initialize(poolKey, INIT_SQRT_PRICE);

        // Get the deployed pair
        pair = IV2OnV4Pair(factory.getPair(address(token0), address(token1)));

        // Mint tokens to test users
        _mintTokensToUsers();

        // Approve tokens for users to interact with V4 manager
        _setupApprovals();

        // Label addresses for better trace output
        vm.label(address(manager), "PoolManager");
        vm.label(address(factory), "V2OnV4Factory");
        vm.label(address(pair), "V2OnV4Pair");
        vm.label(address(token0), "Token0");
        vm.label(address(token1), "Token1");
        vm.label(address(swapRouter), "SwapRouter");
        vm.label(alice, "Alice");
    }

    function _mintTokensToUsers() internal {
        // Mint tokens to test users
        token0.mint(alice, INIT_TOKEN_BALANCE);
        token1.mint(alice, INIT_TOKEN_BALANCE);

        // Also mint to test contract for certain operations
        token0.mint(address(this), INIT_TOKEN_BALANCE);
        token1.mint(address(this), INIT_TOKEN_BALANCE);
    }

    function _setupApprovals() internal {
        // Approve manager for test contract
        token0.approve(address(manager), type(uint256).max);
        token1.approve(address(manager), type(uint256).max);

        // Approve manager for alice
        vm.startPrank(alice);
        token0.approve(address(manager), type(uint256).max);
        token1.approve(address(manager), type(uint256).max);
        token0.approve(address(claimManager), type(uint256).max);
        token1.approve(address(claimManager), type(uint256).max);
        vm.stopPrank();
    }

    function testAddLiquidityClaims() public {
        vm.startPrank(alice);
        claimManager.mint(Currency.wrap(address(token0)), 1 ether);
        claimManager.mint(Currency.wrap(address(token1)), 1 ether);
        manager.transfer(address(pair), Currency.wrap(address(token0)).toId(), 1 ether);
        manager.transfer(address(pair), Currency.wrap(address(token1)).toId(), 1 ether);
        vm.expectEmit(true, true, true, true);
        emit IV2OnV4Pair.Mint(alice, 1 ether, 1 ether);
        pair.mintClaims(alice);
        vm.snapshotGasLastCall("V2OnV4Hook_AddLiquidityClaim");
        vm.assertEq(IERC20(address(pair)).balanceOf(alice), 1 ether - 1000);
        vm.assertEq(manager.balanceOf(address(pair), Currency.wrap(address(token0)).toId()), 1 ether);
        vm.assertEq(manager.balanceOf(address(pair), Currency.wrap(address(token1)).toId()), 1 ether);
    }

    function testAddLiquidity() public {
        vm.startPrank(alice);
        token0.mint(address(pair), 1 ether);
        token1.mint(address(pair), 1 ether);
        vm.expectEmit(true, true, true, true);
        emit IV2OnV4Pair.Mint(address(manager), 1 ether, 1 ether);
        pair.mint(alice);
        vm.snapshotGasLastCall("V2OnV4Hook_AddLiquidity");
        vm.assertEq(IERC20(address(pair)).balanceOf(alice), 1 ether - 1000);
        vm.assertEq(manager.balanceOf(address(pair), Currency.wrap(address(token0)).toId()), 1 ether);
        vm.assertEq(manager.balanceOf(address(pair), Currency.wrap(address(token1)).toId()), 1 ether);
    }

    function testSwapClaims() public {
        _addLiquidity(10 ether, 10 ether);

        vm.startPrank(alice);
        claimManager.mint(Currency.wrap(address(token0)), 1 ether);
        manager.transfer(address(pair), Currency.wrap(address(token0)).toId(), 1 ether);

        vm.expectEmit(true, true, true, true);
        emit IV2OnV4Pair.Swap(alice, 1 ether, 0, 0, 0.5 ether, alice);
        pair.swapClaims(0, 0.5 ether, alice, new bytes(0));
        vm.snapshotGasLastCall("V2OnV4Hook_SwapClaim");
    }

    function testSwapClaimsTooMuchOutput() public {
        _addLiquidity(10 ether, 10 ether);

        vm.startPrank(alice);
        claimManager.mint(Currency.wrap(address(token0)), 1 ether);
        manager.transfer(address(pair), Currency.wrap(address(token0)).toId(), 1 ether);

        vm.expectRevert(IV2OnV4Pair.K.selector);
        pair.swapClaims(0, 1 ether, alice, new bytes(0));
    }

    function testSwapToken0() public {
        _addLiquidity(10 ether, 10 ether);

        vm.startPrank(alice);
        token0.mint(address(pair), 1 ether);

        vm.expectEmit(true, true, true, true);
        emit IV2OnV4Pair.Swap(address(manager), 1 ether, 0, 0, 0.5 ether, alice);
        pair.swap(0, 0.5 ether, alice, new bytes(0));
        vm.snapshotGasLastCall("V2OnV4Hook_Swap");
    }

    function testSwapToken1() public {
        _addLiquidity(10 ether, 10 ether);

        vm.startPrank(alice);
        token1.mint(address(pair), 1 ether);

        vm.expectEmit(true, true, true, true);
        emit IV2OnV4Pair.Swap(address(manager), 0, 1 ether, 0.5 ether, 0, alice);
        pair.swap(0.5 ether, 0, alice, new bytes(0));
    }

    function testSwapTooMuchOutput() public {
        _addLiquidity(10 ether, 10 ether);

        vm.startPrank(alice);
        token0.mint(address(pair), 1 ether);

        vm.expectRevert(IV2OnV4Pair.K.selector);
        pair.swap(0, 1 ether, alice, new bytes(0));
    }

    function _addLiquidity(uint256 amount0, uint256 amount1) internal {
        vm.startPrank(alice);
        token0.mint(address(pair), amount0);
        token1.mint(address(pair), amount1);
        pair.mint(alice);
        vm.stopPrank();
    }
}
