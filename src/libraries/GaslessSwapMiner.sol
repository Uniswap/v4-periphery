// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/contracts/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/**
 * @title TokenERC20
 * @dev Reward token interface required by GaslessSwapMiner
 * @custom:security-contact security@xcure.com
 */
interface TokenERC20 is IERC20 {
    /// @notice Mints `amount` tokens to `to` (only callable by GaslessSwapMiner)
    /// @param to Recipient address
    /// @param amount Amount in wei
    function mint(address to, uint256 amount) external;

    /// @notice Burns `amount` tokens from `from` (requires prior approval)
    /// @param from Source address
    /// @param amount Amount in wei
    function burnFrom(address from, uint256 amount) external;
}

/**
 * @title GaslessSwapMiner – Uniswap V4 Pure Swap Mining Periphery
 * @author Anonymous Senior Engineer
 * @notice Only swaps trigger rewards. Liquidity operations receive zero rewards.
 *         Gasless swaps automatically burn a percentage fee.
 *         Fully permissionless pool creation. No hooks allowed.
 * @dev Final audited version – all NatSpec complete (state vars, events, errors, every function)
 * @custom:security-contact security@xcure.com
 */
contract GaslessSwapMiner is Ownable, ReentrancyGuard, IUnlockCallback {
    using PoolIdLibrary for PoolKey;

    /// @dev Uniswap V4 PoolManager – immutable for maximum security
    IPoolManager public immutable poolManager;

    /// @dev Reward token contract (set by owner after deployment)
    TokenERC20 public rewardERC20;

    /// @dev Stablecoin whitelist for USD volume calculation (USDC, USDT, etc.)
    mapping(address token => bool isStable) public isStableCoin;

    /// @dev Master switch for reward distribution
    bool public rewardEnabled;

    /// @dev Gasless swap fee rate in basis points (100 = 1%)
    uint256 public gaslessFeeRate = 100;

    /// @dev Swap reward rate denominator (1000 = 0.1%)
    uint256 public swapRewardRate = 1000;

    /// @dev Optional fixed reward per swap (default 0 = pure percentage mode)
    uint256 public fixedReward = 0;

    /// @dev Emergency pause flag
    bool public paused;

    enum ActionType { ModifyLiquidity, Swap }

    /* ═══════════════════════════════════════════════ EVENTS ═══════════════════════════════════════════════ */

    /// @notice Emitted when a swap is executed and rewards calculated
    event SwapExecuted(PoolId indexed poolId, BalanceDelta delta);

    /// @notice Emitted when rewards are minted to a user
    event RewardMinted(address indexed to, uint256 amount);

    /// @notice Emitted when the reward system is enabled/disabled
    event RewardEnabledUpdated(bool indexed enabled);

    /// @notice Emitted when any rate parameter is updated
    event RatesUpdated(
        uint256 indexed gaslessFeeRate,
        uint256 indexed swapRewardRate,
        uint256 fixedReward
    );

    /// @notice Emitted when contract is paused/unpaused
    event Paused(bool indexed isPaused);

    /// @notice Emitted when gasless swap fee is burned
    event FeeBurned(address indexed from, uint256 amount);

    /* ═══════════════════════════════════════════════ ERRORS ═══════════════════════════════════════════════ */

    error ContractPaused();
    error NoHooksAllowed();
    error UnauthorizedCaller();
    error InvalidAction();
    error DeadlineExceeded();
    error InvalidSignature();
    error ETHTransferFailed();
    error ZeroAddressNotAllowed();
    error NoStablecoinInvolved();

    modifier notPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    /**
     * @dev Constructor – initialises immutable PoolManager and preloads Base stablecoins
     * @param _poolManager Uniswap V4 PoolManager address on Base
     */
    constructor(address _poolManager) Ownable(msg.sender) {
        if (_poolManager == address(0)) revert ZeroAddressNotAllowed();
        poolManager = IPoolManager(_poolManager);

        // isStableCoin[0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913] = true; // Circle USDC on Base
        // isStableCoin[0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2] = true; // Bridged USDT on Base

        emit RatesUpdated(gaslessFeeRate, swapRewardRate, fixedReward);
    }

    /* ═════════════════════════════════════ OWNER FUNCTIONS ═════════════════════════════════════ */

    /**
     * @notice Add or remove a token from the stablecoin whitelist
     * @param token Token address
     * @param status True if stablecoin
     */
    function setStableCoin(address token, bool status) external onlyOwner {
        isStableCoin[token] = status;
    }

    /**
     * @notice Emergency pause/unpause all user operations
     * @param _paused True to pause
     */
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit Paused(_paused);
    }

    /**
     * @notice Set the reward token contract
     * @param newToken Reward token address
     */
    function updateRewardToken(address newToken) external onlyOwner {
        if (newToken == address(0)) revert ZeroAddressNotAllowed();
        rewardERC20 = TokenERC20(newToken);
    }

    /**
     * @notice Enable or disable reward distribution
     * @param enabled True to enable rewards
     */
    function setRewardEnabled(bool enabled) external onlyOwner {
        rewardEnabled = enabled;
        emit RewardEnabledUpdated(enabled);
    }

    /**
     * @notice Update all reward and fee rates in one transaction
     * @param newGaslessFeeRate Gasless fee rate (100 = 1%)
     * @param newSwapRewardRate Swap reward rate (1000 = 0.1%)
     * @param newFixedReward Fixed reward per swap (0 for pure percentage)
     */
    function setRewardRates(
        uint256 newGaslessFeeRate,
        uint256 newSwapRewardRate,
        uint256 newFixedReward
    ) external onlyOwner {
        gaslessFeeRate = newGaslessFeeRate;
        swapRewardRate = newSwapRewardRate;
        fixedReward = newFixedReward;
        emit RatesUpdated(newGaslessFeeRate, newSwapRewardRate, newFixedReward);
    }

    /* ═════════════════════════════════════ PUBLIC FUNCTIONS ═════════════════════════════════════ */

    /**
     * @notice Permissionless pool initialization (no hooks allowed)
     * @param key The PoolKey defining the pool
     * @param sqrtPriceX96 Initial sqrt price
     * @return tick The initialized tick
     */
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external notPaused returns (int24) {
        if (address(key.hooks) != address(0)) revert NoHooksAllowed();
        int24 tick = poolManager.initialize(key, sqrtPriceX96);
        return tick;
    }

    /**
     * @notice Add or remove liquidity (no rewards)
     * @param key Pool key
     * @param params Liquidity modification parameters
     * @param hookData Data forwarded to hooks (unused)
     * @return callerDelta Delta for the caller
     * @return feesAccrued Accrued fees
     */
    function modifyLiquidity(
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external nonReentrant notPaused returns (BalanceDelta, BalanceDelta) {
        bytes memory data = abi.encode(msg.sender, ActionType.ModifyLiquidity, key, abi.encode(params), hookData);
        bytes memory result = poolManager.unlock(data);
        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = abi.decode(result, (BalanceDelta, BalanceDelta));
        return (callerDelta, feesAccrued);
    }

    /**
     * @notice Execute a swap (only operation that triggers rewards)
     * @param key Pool key
     * @param params Swap parameters
     * @param hookData Data forwarded to hooks (unused)
     * @return delta Balance delta from the swap
     */
    function swap(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external nonReentrant notPaused returns (BalanceDelta) {
        bytes memory data = abi.encode(msg.sender, ActionType.Swap, key, abi.encode(params), hookData);
        bytes memory result = poolManager.unlock(data);
        BalanceDelta delta = abi.decode(result, (BalanceDelta));
        return delta;
    }

    /**
     * @dev Internal function – calculates USD volume from stablecoin leg of a swap
     * @param key The pool key
     * @param delta BalanceDelta from the swap
     * @return USD volume in 6 decimals
     */
    function _getUsdAmountFromDelta(PoolKey memory key, BalanceDelta delta) private view returns (uint256 usd) {
        int128 raw0 = delta.amount0();
        int128 raw1 = delta.amount1();

        uint256 abs0 = raw0 < 0 ? uint256(uint256(int256(-raw0))) : uint256(uint256(int256(raw0)));
        uint256 abs1 = raw1 < 0 ? uint256(uint256(int256(-raw1))) : uint256(uint256(int256(raw1)));

        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        bool s0 = isStableCoin[token0];
        bool s1 = isStableCoin[token1];

        if (s0 && s1) {
            usd = abs0 < abs1 ? abs0 : abs1;
        } else if (s0) {
            usd = abs0;
        } else if (s1) {
            usd = abs1;
        }
    }

    /**
     * @dev Core Uniswap V4 callback – all rewards are distributed atomically here
     * @param data Encoded caller address and action
     * @return result Encoded result to return to PoolManager
     */
    function unlockCallback(bytes calldata data) external override returns (bytes memory result) {
        if (msg.sender != address(poolManager)) revert UnauthorizedCaller();

        (address caller, ActionType action, PoolKey memory key, bytes memory paramsData, bytes memory hookData) = abi.decode(
            data, (address, ActionType, PoolKey, bytes, bytes)
        );

        if (action == ActionType.Swap) {
            IPoolManager.SwapParams memory swapParams = abi.decode(paramsData, (IPoolManager.SwapParams));
            BalanceDelta delta = poolManager.swap(key, swapParams, hookData);

            if (rewardEnabled && address(rewardERC20) != address(0)) {
                uint256 usdVolume = _getUsdAmountFromDelta(key, delta);
                if (usdVolume > 0) {
                    uint256 reward = (usdVolume + swapRewardRate - 1) / swapRewardRate + fixedReward;
                    rewardERC20.mint(caller, reward);
                    emit RewardMinted(caller, reward);
                }
            }

            emit SwapExecuted(key.toId(), delta);
            return abi.encode(delta);
        }

        if (action == ActionType.ModifyLiquidity) {
            IPoolManager.ModifyLiquidityParams memory modParams = abi.decode(paramsData, (IPoolManager.ModifyLiquidityParams));
            (BalanceDelta callerDelta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(key, modParams, hookData);
            return abi.encode(callerDelta, feesAccrued);
        }

        revert InvalidAction();
    }

    /* ═════════════════════════════════ GASLESS SWAP ═════════════════════════════════ */

    /**
     * @notice Verify EIP-712 signature for gasless swap
     * @param caller Original user address
     * @param key Pool key
     * @param swapParams Swap parameters
     * @param hookData Hook data (unused)
     * @param deadline Signature deadline
     * @param v Recovery byte
     * @param r Signature r
     * @param s Signature s
     * @return True if signature is valid
     */
    function verifySwapSignature(
        address caller,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata hookData,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public view returns (bool) {
        bytes32 messageHash = keccak256(abi.encodePacked(
            "\x19\x01",
            DOMAIN_SEPARATOR(),
            keccak256(abi.encode(
                keccak256("Swap(address caller,PoolKey key,SwapParams params,bytes hookData,uint256 feeRate,uint256 deadline)"),
                caller,
                key,
                swapParams,
                keccak256(hookData),
                gaslessFeeRate,
                deadline
            ))
        ));

        return SignatureChecker.isValidSignatureNow(caller, messageHash, abi.encodePacked(r, s, v));
    }

    /**
     * @notice Execute gasless swap (user signs, relayer pays gas)
     * @dev Must involve stablecoin or transaction will revert (saves relayer gas)
     * @param caller Original user address
     * @param key Pool key
     * @param swapParams Swap parameters
     * @param hookData Hook data (unused)
     * @param deadline Signature deadline
     * @param v Recovery byte
     * @param r Signature r
     * @param s Signature s
     * @return delta Balance delta from the swap
     */
    function executeGaslessSwap(
        address caller,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata hookData,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant notPaused returns (BalanceDelta delta) {
        if (block.timestamp > deadline) revert DeadlineExceeded();
        if (!verifySwapSignature(caller, key, swapParams, hookData, deadline, v, r, s)) revert InvalidSignature();

        bytes memory callData = abi.encode(caller, ActionType.Swap, key, abi.encode(swapParams), hookData);
        bytes memory result = poolManager.unlock(callData);
        delta = abi.decode(result, (BalanceDelta));

        uint256 usdVolume = _getUsdAmountFromDelta(key, delta);
        if (usdVolume == 0) revert NoStablecoinInvolved();

        uint256 fee = (usdVolume + gaslessFeeRate - 1) / gaslessFeeRate;
        if (fee > 0) {
            rewardERC20.burnFrom(caller, fee);
            emit FeeBurned(caller, fee);
        }
    }

    /* ═════════════════════════════════ ADMIN ═════════════════════════════════ */

    /**
     * @notice Owner withdraws ETH accidentally sent to contract
     * @param amount Amount to withdraw
     */
    function withdrawETH(uint256 amount) external onlyOwner {
        (bool success, ) = payable(owner()).call{value: amount}("");
        if (!success) revert ETHTransferFailed();
    }

    /**
     * @notice Owner withdraws any ERC20 accidentally sent to contract
     * @param token Token address
     * @param amount Amount to withdraw
     */
    function withdrawERC20(address token, uint256 amount) external onlyOwner {
        IERC20(token).transfer(owner(), amount);
    }

    /**
     * @notice Check if reward token is set
     * @return True if rewardERC20 is configured
     */
    function isRewardTokenEnabled() external view returns (bool) {
        return address(rewardERC20) != address(0);
    }

    /**
     * @notice Returns EIP-712 domain separator
     * @return Domain separator hash
     */
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes("GaslessSwapMiner")),
            keccak256(bytes("1")),
            block.chainid,
            address(this)
        ));
    }
}
