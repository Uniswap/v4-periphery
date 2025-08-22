// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {V2OnV4Pair} from "./V2OnV4Pair.sol";
import {IUniswapV2Factory} from "briefcase/protocols/v2-core/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "briefcase/protocols/v2-core/interfaces/IUniswapV2Pair.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BaseHook} from "../../utils/BaseHook.sol";

/// @title Uniswap V2 on Uniswap V4 as a hook
contract V2OnV4FactoryHook is BaseHook, IUniswapV2Factory {
    address public feeTo;
    address public immutable feeToSetter;

    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    error IdenticalAddresses();
    error ZeroAddress();
    error PairExists();
    error Forbidden();
    error FeeToSetterLocked();

    constructor(IPoolManager _manager) BaseHook(_manager) {
        feeToSetter = address(_manager.protocolFeeController());
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            beforeAddLiquidity: true,
            beforeSwap: true,
            beforeSwapReturnDelta: true,
            afterSwap: false,
            afterInitialize: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeDonate: false,
            afterDonate: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, IdenticalAddresses());
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), ZeroAddress());
        require(getPair[token0][token1] == address(0), PairExists()); // single check is sufficient
        bytes memory bytecode = type(V2OnV4Pair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        IUniswapV2Pair(pair).initialize(token0, token1);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function setFeeToSetter(address) external pure {
        revert FeeToSetterLocked();
    }

    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, Forbidden());
        feeTo = _feeTo;
    }
}
