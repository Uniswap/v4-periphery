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
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {LiquidityAmounts} from "../../contracts/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import {NonfungiblePositionManager} from "../../contracts/NonfungiblePositionManager.sol";
import {LiquidityRange, LiquidityRangeId, LiquidityRangeIdLibrary} from "../../contracts/types/LiquidityRange.sol";


contract GasTest is Test, Deployers, GasSnapshot {
    using FixedPointMathLib for uint256;
    using CurrencyLibrary for Currency;
    using LiquidityRangeIdLibrary for LiquidityRange;
    using PoolIdLibrary for PoolKey;

    NonfungiblePositionManager lpm;

    PoolId poolId;
    address alice = makeAddr("ALICE");
    address bob = makeAddr("BOB");

    uint256 constant STARTING_USER_BALANCE = 10_000_000 ether;

    // unused value for the fuzz helper functions
    uint128 constant DEAD_VALUE = 6969.6969 ether;

    // expresses the fee as a wad (i.e. 3000 = 0.003e18 = 0.30%)
    uint256 FEE_WAD;

    LiquidityRange range;

    function setUp() public {
        Deployers.deployFreshManagerAndRouters();
        Deployers.deployMintAndApprove2Currencies();

        (key, poolId) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1, ZERO_BYTES);
        FEE_WAD = uint256(key.fee).mulDivDown(FixedPointMathLib.WAD, 1_000_000);

        lpm = new NonfungiblePositionManager(manager);
        IERC20(Currency.unwrap(currency0)).approve(address(lpm), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(lpm), type(uint256).max);

        // mint some ERC6909 tokens
        claimsRouter.deposit(currency0, address(this), 100_000_000 ether);
        claimsRouter.deposit(currency1, address(this), 100_000_000 ether);
        manager.setOperator(address(lpm), true);

        // define a reusable range
        range = LiquidityRange({key: key, tickLower: -300, tickUpper: 300});
    }

    // function test_gas_mint() public {
    //     uint256 amount0Desired = 148873216119575134691; // 148 ether tokens, 10_000 liquidity
    //     uint256 amount1Desired = 148873216119575134691; // 148 ether tokens, 10_000 liquidity
    //     INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
    //         range: range,
    //         amount0Desired: amount0Desired,
    //         amount1Desired: amount1Desired,
    //         amount0Min: 0,
    //         amount1Min: 0,
    //         deadline: block.timestamp + 1,
    //         recipient: address(this),
    //         hookData: ZERO_BYTES
    //     });
    //     snapStart("mint");
    //     lpm.mint(params);
    //     snapEnd();
    // }

    function test_gas_mintWithLiquidity() public {
        snapStart("mintWithLiquidity");
        lpm.mint(range, 10_000 ether, block.timestamp + 1, address(this), ZERO_BYTES);
        snapEnd();
    }

    function test_gas_increaseLiquidity_erc20() public {
        (uint256 tokenId,) = lpm.mint(range, 10_000 ether, block.timestamp + 1, address(this), ZERO_BYTES);

        snapStart("increaseLiquidity_erc20");
        lpm.increaseLiquidity(tokenId, 1000 ether, ZERO_BYTES, false);
        snapEnd();
    }

    function test_gas_increaseLiquidity_erc6909() public {
        (uint256 tokenId,) = lpm.mint(range, 10_000 ether, block.timestamp + 1, address(this), ZERO_BYTES);

        snapStart("increaseLiquidity_erc6909");
        lpm.increaseLiquidity(tokenId, 1000 ether, ZERO_BYTES, true);
        snapEnd();
    }

    function test_gas_decreaseLiquidity_erc20() public {
        (uint256 tokenId,) = lpm.mint(range, 10_000 ether, block.timestamp + 1, address(this), ZERO_BYTES);

        snapStart("decreaseLiquidity_erc20");
        lpm.decreaseLiquidity(tokenId, 10_000 ether, ZERO_BYTES, false);
        snapEnd();
    }

    function test_gas_decreaseLiquidity_erc6909() public {
        (uint256 tokenId,) = lpm.mint(range, 10_000 ether, block.timestamp + 1, address(this), ZERO_BYTES);

        snapStart("decreaseLiquidity_erc6909");
        lpm.decreaseLiquidity(tokenId, 10_000 ether, ZERO_BYTES, true);
        snapEnd();
    }

    function test_gas_burn() public {}
    function test_gas_burnEmpty() public {}
    function test_gas_collect() public {}
}
