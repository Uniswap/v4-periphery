// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IUniswapV2Callee} from "briefcase/protocols/v2-core/interfaces/IUniswapV2Callee.sol";
import {IUniswapV2Factory} from "briefcase/protocols/v2-core/interfaces/IUniswapV2Factory.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BaseHook} from "../../utils/BaseHook.sol";
import {V2OnV4PairDeployer} from "./V2OnV4PairDeployer.sol";
import {UQ112x112} from "./UQ112x112.sol";
import {IV2OnV4Pair} from "../../interfaces/IV2OnV4Pair.sol";

enum UnlockCallbackAction {
    MINT,
    BURN,
    SWAP
}

struct UnlockCallback {
    UnlockCallbackAction action;
    address to;
    bytes data;
}

/// @title V2OnV4Pair
/// @author Uniswap Labs
/// @notice A V2-style AMM pair contract that operates on Uniswap V4 infrastructure
/// @dev Implements constant product (x*y=k) AMM logic while leveraging V4's singleton pool manager
contract V2OnV4Pair is IV2OnV4Pair, ERC20, ReentrancyGuardTransient {
    using UQ112x112 for uint224;
    using SafeTransferLib for ERC20;
    using CurrencyLibrary for Currency;

    /// @notice Minimum liquidity locked when first LP tokens are minted
    /// @dev Prevents division by zero and protects against manipulation
    uint256 public constant MINIMUM_LIQUIDITY = 10 ** 3;

    /// @notice The Uniswap V4 pool manager contract
    IPoolManager public immutable poolManager;

    /// @notice Address of the factory that deployed this pair
    address public immutable factory;

    Currency public immutable token0;
    Currency public immutable token1;

    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;

    /// @notice Cumulative price of token0 in terms of token1, used for TWAP oracles
    uint256 public price0CumulativeLast;

    /// @notice Cumulative price of token1 in terms of token0, used for TWAP oracles
    uint256 public price1CumulativeLast;

    /// @notice Product of reserves (k value) after last liquidity event, used for protocol fee calculation
    uint256 public kLast;

    /// @notice Returns the current reserves and last update timestamp
    /// @return _reserve0 Current reserve of token0
    /// @return _reserve1 Current reserve of token1
    /// @return _blockTimestampLast Timestamp of last reserve update
    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    /// @notice Only allow calls from the PoolManager contract
    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @notice Deploys a new V2 pair on V4
    /// @dev Called by the factory with deployment parameters
    constructor() ERC20("Uniswap V2", "UNI-V2", 18) {
        (address _token0, address _token1, address _poolManager) = V2OnV4PairDeployer(msg.sender).parameters();
        token0 = Currency.wrap(_token0);
        token1 = Currency.wrap(_token1);
        poolManager = IPoolManager(_poolManager);
        factory = msg.sender;
    }

    // V2 STYLE ERC20 FUNCTIONS

    /// @notice Mints liquidity tokens to the specified address
    /// @dev Low-level function that should be called through a router with proper safety checks
    /// @param to Address to receive the minted LP tokens
    /// @return liquidity Amount of LP tokens minted
    function mint(address to) external override nonReentrant returns (uint256 liquidity) {
        (liquidity) = abi.decode(
            poolManager.unlock(
                abi.encode(UnlockCallback({action: UnlockCallbackAction.MINT, to: to, data: new bytes(0)}))
            ),
            (uint256)
        );
    }

    /// @notice Internal mint function that handles ERC20 token deposits and liquidity creation
    /// @dev Converts ERC20 tokens to V4 claims and mints LP tokens. Must be called when V4 is unlocked
    /// @param to Address to receive the minted LP tokens
    /// @return liquidity Amount of LP tokens minted
    function _mint(address to) internal returns (uint256 liquidity) {
        // transform ERC20 tokens into claims
        _slurp();
        // Then mint liquidity as normal with those claims
        liquidity = _mintClaims(to);
    }

    /// @notice Burns liquidity tokens and returns underlying assets
    /// @dev Low-level function that should be called through a router with proper safety checks
    /// @param to Address to receive the underlying tokens
    /// @return amount0 Amount of token0 returned
    /// @return amount1 Amount of token1 returned
    function burn(address to) external override nonReentrant returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = abi.decode(
            poolManager.unlock(
                abi.encode(UnlockCallback({action: UnlockCallbackAction.BURN, to: to, data: new bytes(0)}))
            ),
            (uint256, uint256)
        );
    }

    /// @notice Internal burn function that redeems LP tokens for underlying assets
    /// @dev Burns LP tokens and transfers underlying tokens via V4 claims system
    /// @param to Address to receive the underlying tokens
    /// @return amount0 Amount of token0 returned
    /// @return amount1 Amount of token1 returned
    function _burn(address to) internal returns (uint256 amount0, uint256 amount1) {
        // burn the liquidity tokens and transfer claims to the recipient
        (amount0, amount1) = _burnClaims(to, false);
    }

    /// @notice Executes a swap with specified output amounts
    /// @dev Low-level function enforcing constant product invariant (x*y=k)
    /// @param amount0Out Amount of token0 to send
    /// @param amount1Out Amount of token1 to send
    /// @param to Address to receive output tokens
    /// @param data Callback data for flash swaps
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data)
        external
        override
        nonReentrant
    {
        poolManager.unlock(
            abi.encode(
                UnlockCallback({
                    action: UnlockCallbackAction.SWAP,
                    to: to,
                    data: abi.encode(amount0Out, amount1Out, data)
                })
            )
        );
    }

    /// @notice Internal swap function that executes token swaps
    /// @dev Converts input tokens to claims, performs swap, and sends output tokens to recipient
    /// @param amount0Out Amount of token0 to send to recipient
    /// @param amount1Out Amount of token1 to send to recipient
    /// @param to Address to receive output tokens
    /// @param data Callback data for flash swaps
    function _swap(uint256 amount0Out, uint256 amount1Out, address to, bytes memory data) internal {
        _slurp();
        _swapClaims(amount0Out, amount1Out, to, data, false);
    }

    /// @notice Transfers excess tokens to maintain balance-reserve parity
    /// @dev Useful for recovering tokens sent directly to the pair
    /// @param to Address to receive excess tokens
    function skim(address to) external nonReentrant {
        poolManager.transfer(to, token0.toId(), poolManager.balanceOf(address(this), token0.toId()) - reserve0);
        poolManager.transfer(to, token1.toId(), poolManager.balanceOf(address(this), token1.toId()) - reserve1);
    }

    /// @notice Synchronizes reserves with current balances
    /// @dev Updates reserves to match actual token balances
    function sync() external nonReentrant {
        _update(
            poolManager.balanceOf(address(this), token0.toId()),
            poolManager.balanceOf(address(this), token1.toId()),
            reserve0,
            reserve1
        );
    }

    // V4 STYLE CLAIMS FUNCTIONS

    /// @notice Mints liquidity using V4 claims directly
    /// @dev Assumes claims are already in the contract, does not handle ERC20 token deposits
    /// @param to Address to receive the minted LP tokens
    /// @return liquidity Amount of LP tokens minted
    function mintClaims(address to) external nonReentrant returns (uint256 liquidity) {
        return _mintClaims(to);
    }

    /// @notice Burns liquidity and returns claims directly
    /// @dev Returns V4 claims instead of ERC20 tokens, useful for composability
    /// @param to Address to receive the claims
    /// @return amount0 Amount of token0 claims returned
    /// @return amount1 Amount of token1 claims returned
    function burnClaims(address to) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        return _burnClaims(to, true);
    }

    /// @notice Executes a swap using V4 claims directly
    /// @dev Operates entirely within the V4 claims system without ERC20 token transfers
    /// @param amount0Out Amount of token0 claims to send
    /// @param amount1Out Amount of token1 claims to send
    /// @param to Address to receive output claims
    /// @param data Callback data for flash swaps
    function swapClaims(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data)
        external
        nonReentrant
    {
        _swapClaims(amount0Out, amount1Out, to, data, true);
    }

    /// @notice Callback executed by pool manager during unlock operations
    /// @dev Routes to appropriate internal function based on action type (mint/burn/swap)
    /// @param data Encoded UnlockCallback struct containing action type and parameters
    /// @return Empty bytes as no return data is needed
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        UnlockCallback memory callbackData = abi.decode(data, (UnlockCallback));
        if (callbackData.action == UnlockCallbackAction.MINT) {
            return abi.encode(_mint(callbackData.to));
        } else if (callbackData.action == UnlockCallbackAction.BURN) {
            (uint256 amount0, uint256 amount1) = _burn(callbackData.to);
            return abi.encode(amount0, amount1);
        } else if (callbackData.action == UnlockCallbackAction.SWAP) {
            (uint256 amount0Out, uint256 amount1Out, bytes memory swapData) =
                abi.decode(callbackData.data, (uint256, uint256, bytes));
            _swap(amount0Out, amount1Out, callbackData.to, swapData);
            return new bytes(0); // no return data needed for swap
        } else {
            revert InvalidUnlockCallbackData();
        }
    }

    // INTERNAL FUNCTIONS

    /// @notice Burns liquidity tokens and returns underlying assets
    /// @dev Low-level function that should be called through a router with proper safety checks
    /// @param to Address to receive the underlying tokens
    /// @param claimOutput true if the user should receive claims, false if they should receive raw ERC20 tokens
    /// @return amount0 Amount of token0 returned
    /// @return amount1 Amount of token1 returned
    function _burnClaims(address to, bool claimOutput) internal returns (uint256 amount0, uint256 amount1) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        uint256 balance0 = poolManager.balanceOf(address(this), token0.toId());
        uint256 balance1 = poolManager.balanceOf(address(this), token1.toId());
        uint256 liquidity = balanceOf[address(this)];

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint256 _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        amount0 = liquidity * balance0 / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = liquidity * balance1 / _totalSupply; // using balances ensures pro-rata distribution
        require(amount0 > 0 && amount1 > 0, InsufficientLiquidityBurned());
        _burn(address(this), liquidity);
        _transfer(token0, to, amount0, claimOutput);
        _transfer(token1, to, amount1, claimOutput);
        balance0 = poolManager.balanceOf(address(this), token0.toId());
        balance1 = poolManager.balanceOf(address(this), token1.toId());

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint256(reserve0) * reserve1; // reserve0 and reserve1 are up-to-date
        emit Burn(msg.sender, amount0, amount1, to);
    }

    /// @notice Mints liquidity tokens to the specified address
    /// @dev Low-level function that should be called through a router with proper safety checks
    /// @param to Address to receive the minted LP tokens
    /// @return liquidity Amount of LP tokens minted
    function _mintClaims(address to) internal returns (uint256 liquidity) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        uint256 balance0 = poolManager.balanceOf(address(this), token0.toId());
        uint256 balance1 = poolManager.balanceOf(address(this), token1.toId());
        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 - _reserve1;

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint256 _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        if (_totalSupply == 0) {
            liquidity = FixedPointMathLib.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {
            liquidity = _min(amount0 * _totalSupply / _reserve0, amount1 * _totalSupply / _reserve1);
        }
        require(liquidity > 0, InsufficientLiquidityMinted());
        _mint(to, liquidity);

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint256(reserve0) * reserve1; // reserve0 and reserve1 are up-to-date
        emit Mint(msg.sender, amount0, amount1);
    }

    /// @notice Executes a swap with specified output amounts
    /// @dev Low-level function enforcing constant product invariant (x*y=k)
    /// @param amount0Out Amount of token0 to send
    /// @param amount1Out Amount of token1 to send
    /// @param to Address to receive output tokens
    /// @param data Callback data for flash swaps
    /// @param claimOutput true if the user should receive claims, false if they should receive raw ERC20 tokens
    function _swapClaims(uint256 amount0Out, uint256 amount1Out, address to, bytes memory data, bool claimOutput)
        internal
    {
        require(amount0Out > 0 || amount1Out > 0, InsufficientOutputAmount());
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        require(amount0Out < _reserve0 && amount1Out < _reserve1, InsufficientLiquidity()); // ensure that there is enough liquidity to perform the swap

        uint256 balance0;
        uint256 balance1;
        {
            // scope for _token{0,1}, avoids stack too deep errors
            require(to != Currency.unwrap(token0) && to != Currency.unwrap(token1), InvalidTo());
            if (amount0Out > 0) _transfer(token0, to, amount0Out, claimOutput); // optimistically transfer tokens
            if (amount1Out > 0) _transfer(token1, to, amount1Out, claimOutput); // optimistically transfer tokens
            if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);
            balance0 = poolManager.balanceOf(address(this), token0.toId());
            balance1 = poolManager.balanceOf(address(this), token1.toId());
        }
        uint256 amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint256 amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, InsufficientInputAmount());
        {
            // scope for reserve{0,1}Adjusted, avoids stack too deep errors
            uint256 balance0Adjusted = (balance0 * 1000) - (amount0In * 3);
            uint256 balance1Adjusted = (balance1 * 1000) - (amount1In * 3);
            require(balance0Adjusted * balance1Adjusted >= uint256(_reserve0) * _reserve1 * (1000 ** 2), K());
        }

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    /// @notice Updates reserves and price accumulators
    /// @dev Called after every liquidity or swap operation to maintain price oracle
    /// @param balance0 New balance of token0
    /// @param balance1 New balance of token1
    /// @param _reserve0 Previous reserve of token0
    /// @param _reserve1 Previous reserve of token1
    function _update(uint256 balance0, uint256 balance1, uint112 _reserve0, uint112 _reserve1) private {
        uint32 blockTimestamp = uint32(block.timestamp % 2 ** 32);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // * never overflows, and + overflow is desired
            price0CumulativeLast += uint256(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint256(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    /// @notice Mints protocol fee as LP tokens if enabled
    /// @dev Calculates fee as 1/6th of sqrt(k) growth since last fee collection
    /// @param _reserve0 Current reserve of token0
    /// @param _reserve1 Current reserve of token1
    /// @return feeOn Whether protocol fee is enabled
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        address feeTo = IUniswapV2Factory(factory).feeTo();
        feeOn = feeTo != address(0);
        uint256 _kLast = kLast; // gas savings
        if (feeOn) {
            if (_kLast != 0) {
                uint256 rootK = FixedPointMathLib.sqrt(uint256(_reserve0) * _reserve1);
                uint256 rootKLast = FixedPointMathLib.sqrt(_kLast);
                if (rootK > rootKLast) {
                    uint256 numerator = totalSupply * (rootK - rootKLast);
                    uint256 denominator = rootK * 5 / rootKLast;
                    uint256 liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    /// @notice Returns the minimum of two values
    /// @param a First value
    /// @param b Second value
    /// @return The smaller of the two values
    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? uint256(a) : b;
    }

    /// @notice Settles tokens with the V4 pool manager
    /// @dev Handles both native ETH and ERC20 token settlements
    /// @dev must be run when v4 is unlocked
    /// @param currency The currency to settle
    /// @return amount The amount settled
    function _settle(Currency currency) internal returns (uint256 amount) {
        amount = currency.balanceOfSelf();
        if (amount == 0) return 0;

        poolManager.sync(currency);
        if (currency.isAddressZero()) {
            poolManager.settle{value: amount}();
        } else {
            currency.transfer(address(poolManager), amount);
            poolManager.settle();
        }
    }

    /// @notice Converts all ERC20 tokens held by the pair into V4 claims
    /// @dev Settles tokens with pool manager and mints equivalent claims. Must be called when V4 is unlocked
    /// @return amount0 Amount of token0 converted to claims
    /// @return amount1 Amount of token1 converted to claims
    function _slurp() internal returns (uint256 amount0, uint256 amount1) {
        amount0 = _settle(token0);
        amount1 = _settle(token1);

        // mint into new claims
        if (amount0 > 0) poolManager.mint(address(this), token0.toId(), amount0);
        if (amount1 > 0) poolManager.mint(address(this), token1.toId(), amount1);
    }

    /// @notice Transfers The given asset to the recipient, either as a claim or as a raw ERC20 token
    function _transfer(Currency currency, address to, uint256 amount, bool claim) internal {
        if (claim) {
            poolManager.transfer(to, currency.toId(), amount);
        } else {
            poolManager.burn(address(this), currency.toId(), amount);
            poolManager.take(currency, to, amount);
        }
    }

    /// @inheritdoc ReentrancyGuardTransient
    function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
        return false;
    }
}
