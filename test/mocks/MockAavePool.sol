// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IPool} from "../../src/interfaces/external/aave/IPool.sol";
import {IPoolAddressesProvider} from "../../src/interfaces/external/aave/IPoolAddressesProvider.sol";
import {IPoolDataProvider} from "../../src/interfaces/external/aave/IPoolDataProvider.sol";

/// @notice Aave v3 addresses provider stand-in: resolves the Pool and protocol data provider proxy
///         addresses the adapter reads at construction.
contract MockAaveAddressesProvider is IPoolAddressesProvider {
    address internal immutable _pool;
    address internal immutable _dataProvider;

    constructor(address pool_, address dataProvider_) {
        _pool = pool_;
        _dataProvider = dataProvider_;
    }

    /// @inheritdoc IPoolAddressesProvider
    function getPool() external view returns (address) {
        return _pool;
    }

    /// @inheritdoc IPoolAddressesProvider
    function getPoolDataProvider() external view returns (address) {
        return _dataProvider;
    }
}

/// @notice Aave v3 Pool stand-in modeling the surface the lending adapter and the margin flows use:
///         supply, withdraw, borrow, repay, and the account-level health read. aToken and variable
///         debt receipts are minimal `MockERC20`s the pool mints and burns; per-reserve metadata
///         (receipt tokens, USD-base price, liquidation threshold) is registered through
///         `registerReserve`. The pool must be pre-funded with each borrowable asset so `borrow` can
///         deliver the underlying to `msg.sender` (the account), which is what exercises the
///         account's borrow-then-forward path.
contract MockAavePool is IPool {
    using SafeERC20 for IERC20;

    /// @notice Per-reserve metadata for a registered asset.
    /// @param aToken The supply receipt token minted on supply and burned on withdraw.
    /// @param vDebt The variable debt receipt token minted on borrow and burned on repay.
    /// @param priceBase The asset price in the protocol USD base (8 decimals; 1e8 == $1).
    /// @param decimals The asset decimals, used to normalize balances into the USD base.
    /// @param liquidationThresholdBps The liquidation threshold in basis points (1e4 == 100%).
    /// @param registered Whether the reserve has been registered.
    struct Reserve {
        MockERC20 aToken;
        MockERC20 vDebt;
        uint256 priceBase;
        uint8 decimals;
        uint256 liquidationThresholdBps;
        bool registered;
    }

    mapping(address asset => Reserve reserve) internal _reserves;
    /// @notice The set of registered assets, walked by `getUserAccountData` to total a user position.
    address[] internal _assets;

    /// @notice Registers a reserve so the pool can mint/burn its receipts and value it in the USD base.
    /// @param asset The underlying reserve asset.
    /// @param aToken The supply receipt token for the asset.
    /// @param vDebt The variable debt receipt token for the asset.
    /// @param priceBase The asset price in the USD base (8 decimals; 1e8 == $1).
    /// @param liquidationThresholdBps The liquidation threshold in basis points.
    function registerReserve(
        address asset,
        MockERC20 aToken,
        MockERC20 vDebt,
        uint256 priceBase,
        uint256 liquidationThresholdBps
    ) external {
        if (!_reserves[asset].registered) _assets.push(asset);
        _reserves[asset] = Reserve({
            aToken: aToken,
            vDebt: vDebt,
            priceBase: priceBase,
            decimals: IERC20Decimals(asset).decimals(),
            liquidationThresholdBps: liquidationThresholdBps,
            registered: true
        });
    }

    /// @inheritdoc IPool
    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        _reserves[asset].aToken.mint(onBehalfOf, amount);
    }

    /// @inheritdoc IPool
    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        _reserves[asset].aToken.burn(msg.sender, amount);
        IERC20(asset).safeTransfer(to, amount);
        return amount;
    }

    /// @inheritdoc IPool
    /// @dev Aave's borrow has no receiver: the underlying is sent to `msg.sender` (the account), not a
    ///      receiver, and the variable debt accrues to `onBehalfOf`.
    function borrow(address asset, uint256 amount, uint256, uint16, address onBehalfOf) external {
        _reserves[asset].vDebt.mint(onBehalfOf, amount);
        IERC20(asset).safeTransfer(msg.sender, amount);
    }

    /// @inheritdoc IPool
    /// @dev `amount == type(uint256).max` repays the full variable debt of `onBehalfOf`.
    function repay(address asset, uint256 amount, uint256, address onBehalfOf) external returns (uint256) {
        MockERC20 vDebt = _reserves[asset].vDebt;
        uint256 owed = vDebt.balanceOf(onBehalfOf);
        uint256 pay = amount == type(uint256).max ? owed : amount;
        IERC20(asset).safeTransferFrom(msg.sender, address(this), pay);
        vDebt.burn(onBehalfOf, pay);
        return pay;
    }

    /// @inheritdoc IPool
    /// @dev Totals the user's aToken and variable debt receipt balances across every registered
    ///      reserve, valuing each in the USD base as `balance * priceBase / 10**decimals`. Only
    ///      `totalCollateralBase`, `totalDebtBase`, and `currentLiquidationThreshold` are populated;
    ///      the adapter reads only the first two.
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        )
    {
        for (uint256 i = 0; i < _assets.length; i++) {
            Reserve storage r = _reserves[_assets[i]];
            uint256 scale = 10 ** r.decimals;
            uint256 aBalance = r.aToken.balanceOf(user);
            uint256 dBalance = r.vDebt.balanceOf(user);
            if (aBalance != 0) {
                uint256 collateralBase = aBalance * r.priceBase / scale;
                totalCollateralBase += collateralBase;
                currentLiquidationThreshold = r.liquidationThresholdBps;
            }
            totalDebtBase += dBalance * r.priceBase / scale;
        }
        // availableBorrowsBase, ltv, and healthFactor are unused by the adapter.
        return (totalCollateralBase, totalDebtBase, availableBorrowsBase, currentLiquidationThreshold, ltv, healthFactor);
    }

    /// @notice The variable debt receipt token for a reserve. Test helper for driving the pool.
    /// @param asset The underlying reserve asset.
    /// @return The variable debt receipt token.
    function variableDebtToken(address asset) external view returns (MockERC20) {
        return _reserves[asset].vDebt;
    }

    /// @notice The aToken receipt for a reserve. Test helper for driving the pool.
    /// @param asset The underlying reserve asset.
    /// @return The aToken receipt token.
    function aToken(address asset) external view returns (MockERC20) {
        return _reserves[asset].aToken;
    }

    /// @notice The liquidation threshold a reserve was registered with, read by the data provider.
    /// @param asset The underlying reserve asset.
    /// @return The liquidation threshold in basis points.
    function liquidationThresholdBps(address asset) external view returns (uint256) {
        return _reserves[asset].liquidationThresholdBps;
    }
}

/// @notice Aave v3 protocol data provider stand-in: resolves reserve receipt token addresses and
///         reserve configuration from the registered reserves on a `MockAavePool`. The third
///         configuration value (`liquidationThreshold`) is what the adapter reads for `maxLtvWad`.
contract MockAaveDataProvider is IPoolDataProvider {
    MockAavePool internal immutable pool;

    constructor(MockAavePool pool_) {
        pool = pool_;
    }

    /// @inheritdoc IPoolDataProvider
    /// @dev Mirrors Aave: stable debt is unused, so its address is the zero address.
    function getReserveTokensAddresses(address asset)
        external
        view
        returns (address aTokenAddress, address stableDebtTokenAddress, address variableDebtTokenAddress)
    {
        aTokenAddress = address(pool.aToken(asset));
        stableDebtTokenAddress = address(0);
        variableDebtTokenAddress = address(pool.variableDebtToken(asset));
    }

    /// @inheritdoc IPoolDataProvider
    /// @dev `decimals` is read from the asset; `ltv` is deliberately set to a value distinct from the
    ///      liquidation threshold so a `getLtv`/`getLiquidationThreshold` mixup in the adapter would
    ///      surface. The remaining fields are sensible constants the adapter does not read.
    function getReserveConfigurationData(address asset)
        external
        view
        returns (
            uint256 decimals,
            uint256 ltv,
            uint256 liquidationThreshold,
            uint256 liquidationBonus,
            uint256 reserveFactor,
            bool usageAsCollateralEnabled,
            bool borrowingEnabled,
            bool stableBorrowRateEnabled,
            bool isActive,
            bool isFrozen
        )
    {
        decimals = IERC20Decimals(asset).decimals();
        uint256 threshold = pool.liquidationThresholdBps(asset);
        liquidationThreshold = threshold;
        // ltv (max borrow) sits below the liquidation threshold, as on a real reserve, and is
        // intentionally a different value so the adapter using the wrong field would be caught.
        ltv = threshold == 0 ? 0 : threshold - 200;
        liquidationBonus = 10_500;
        reserveFactor = 1_000;
        usageAsCollateralEnabled = threshold != 0;
        borrowingEnabled = true;
        stableBorrowRateEnabled = false;
        isActive = true;
        isFrozen = false;
    }
}

/// @notice Decimals accessor on an ERC-20, used to normalize balances into the USD base.
interface IERC20Decimals {
    function decimals() external view returns (uint8);
}
