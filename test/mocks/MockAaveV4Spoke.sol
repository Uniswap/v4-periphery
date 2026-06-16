// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {ISpoke} from "../../src/interfaces/external/aave-v4/ISpoke.sol";

/// @notice Aave v4 Spoke stand-in modeling the surface the lending adapter and the margin flows use:
///         reserveId-keyed supply, withdraw, borrow, repay, collateral enablement, the batching
///         multicall, and the position/account reads. Reserves are registered with their underlying,
///         price, decimals, collateral factor, and Hub; supplied and debt balances are tracked as
///         plain asset amounts (the real Spoke is share-based but exposes asset-denominated reads).
/// @dev    Two behaviors are modeled deliberately because they drive the adapter:
///         - `borrow` and `withdraw` deliver the underlying to `msg.sender` (the account), so the mock
///           must be pre-funded with each borrowable asset.
///         - `multicall` is a true delegatecall-to-self loop, so `msg.sender` is preserved into each
///           call; the supply path relies on this to pull the underlying against the caller's allowance.
contract MockAaveV4Spoke is ISpoke {
    using SafeERC20 for IERC20;

    /// @notice Per-reserve metadata for a registered reserve.
    /// @param underlying The underlying asset.
    /// @param hub The Hub the reserve belongs to.
    /// @param assetId The asset identifier on the Hub.
    /// @param decimals The underlying decimals.
    /// @param priceBase The price in the oracle base (8 decimals; 1e8 == $1).
    /// @param collateralFactorBps The collateral factor in basis points.
    /// @param registered Whether the reserve has been registered.
    struct ReserveData {
        address underlying;
        address hub;
        uint16 assetId;
        uint8 decimals;
        uint256 priceBase;
        uint16 collateralFactorBps;
        bool registered;
    }

    address public immutable ORACLE;

    mapping(uint256 reserveId => ReserveData data) internal _reserves;
    uint256[] internal _reserveIds;
    mapping(uint256 reserveId => mapping(address user => uint256 amount)) internal _supplied;
    mapping(uint256 reserveId => mapping(address user => uint256 amount)) internal _debt;
    mapping(uint256 reserveId => mapping(address user => bool isCollateral)) internal _usingAsCollateral;

    /// @notice The last `msg.sender` observed by `supply`, used to prove multicall preserves the caller.
    address public lastSupplyCaller;

    constructor(address oracle_) {
        ORACLE = oracle_;
    }

    /// @notice Registers a reserve so the Spoke can move its underlying and value it in the base.
    /// @param reserveId The reserve identifier.
    /// @param underlying The underlying asset.
    /// @param hub The Hub the reserve belongs to.
    /// @param assetId The asset identifier on the Hub.
    /// @param priceBase The price in the oracle base (8 decimals).
    /// @param collateralFactorBps The collateral factor in basis points.
    function registerReserve(
        uint256 reserveId,
        address underlying,
        address hub,
        uint16 assetId,
        uint256 priceBase,
        uint16 collateralFactorBps
    ) external {
        if (!_reserves[reserveId].registered) _reserveIds.push(reserveId);
        _reserves[reserveId] = ReserveData({
            underlying: underlying,
            hub: hub,
            assetId: assetId,
            decimals: IERC20Decimals(underlying).decimals(),
            priceBase: priceBase,
            collateralFactorBps: collateralFactorBps,
            registered: true
        });
    }

    /// @inheritdoc ISpoke
    function supply(uint256 reserveId, uint256 amount, address onBehalfOf)
        external
        returns (uint256, uint256)
    {
        lastSupplyCaller = msg.sender;
        IERC20(_reserves[reserveId].underlying).safeTransferFrom(msg.sender, address(this), amount);
        _supplied[reserveId][onBehalfOf] += amount;
        return (amount, amount);
    }

    /// @inheritdoc ISpoke
    /// @dev Delivers the underlying to `msg.sender` and caps an over-amount to the supplied balance.
    function withdraw(uint256 reserveId, uint256 amount, address onBehalfOf)
        external
        returns (uint256, uint256)
    {
        uint256 supplied = _supplied[reserveId][onBehalfOf];
        uint256 withdrawn = amount > supplied ? supplied : amount;
        _supplied[reserveId][onBehalfOf] = supplied - withdrawn;
        IERC20(_reserves[reserveId].underlying).safeTransfer(msg.sender, withdrawn);
        return (withdrawn, withdrawn);
    }

    /// @inheritdoc ISpoke
    /// @dev Delivers the borrowed underlying to `msg.sender`; the mock must be pre-funded.
    function borrow(uint256 reserveId, uint256 amount, address onBehalfOf)
        external
        returns (uint256, uint256)
    {
        _debt[reserveId][onBehalfOf] += amount;
        IERC20(_reserves[reserveId].underlying).safeTransfer(msg.sender, amount);
        return (amount, amount);
    }

    /// @inheritdoc ISpoke
    /// @dev Caps an over-amount to the total debt, so `type(uint256).max` repays in full.
    function repay(uint256 reserveId, uint256 amount, address onBehalfOf)
        external
        returns (uint256, uint256)
    {
        uint256 owed = _debt[reserveId][onBehalfOf];
        uint256 pay = amount > owed ? owed : amount;
        IERC20(_reserves[reserveId].underlying).safeTransferFrom(msg.sender, address(this), pay);
        _debt[reserveId][onBehalfOf] = owed - pay;
        return (pay, pay);
    }

    /// @inheritdoc ISpoke
    function setUsingAsCollateral(uint256 reserveId, bool usingAsCollateral, address onBehalfOf) external {
        _usingAsCollateral[reserveId][onBehalfOf] = usingAsCollateral;
    }

    /// @inheritdoc ISpoke
    /// @dev Delegatecall-to-self so the inner calls observe the original `msg.sender`, exactly like the
    ///      real Spoke. Bubbles the revert reason on failure.
    function multicall(bytes[] calldata data) external returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            (bool ok, bytes memory ret) = address(this).delegatecall(data[i]);
            if (!ok) {
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
            results[i] = ret;
        }
    }

    /// @inheritdoc ISpoke
    function getUserSuppliedAssets(uint256 reserveId, address user) external view returns (uint256) {
        return _supplied[reserveId][user];
    }

    /// @inheritdoc ISpoke
    function getUserTotalDebt(uint256 reserveId, address user) external view returns (uint256) {
        return _debt[reserveId][user];
    }

    /// @inheritdoc ISpoke
    /// @dev Only `totalCollateralValue` and `totalDebtValueRay` are populated; the adapter reads only
    ///      those. Value units are USD scaled by the base (1e8); the debt total is additionally scaled
    ///      by RAY (1e27), matching the live Spoke.
    function getUserAccountData(address user) external view returns (UserAccountData memory data) {
        for (uint256 i = 0; i < _reserveIds.length; i++) {
            uint256 reserveId = _reserveIds[i];
            ReserveData storage r = _reserves[reserveId];
            uint256 scale = 10 ** r.decimals;
            uint256 supplied = _supplied[reserveId][user];
            if (supplied != 0 && _usingAsCollateral[reserveId][user] && r.collateralFactorBps != 0) {
                data.totalCollateralValue += supplied * r.priceBase / scale;
            }
            uint256 debt = _debt[reserveId][user];
            if (debt != 0) {
                data.totalDebtValueRay += (debt * r.priceBase / scale) * 1e27;
            }
        }
    }

    /// @inheritdoc ISpoke
    function getReserve(uint256 reserveId) external view returns (Reserve memory) {
        ReserveData storage r = _reserves[reserveId];
        return Reserve({
            underlying: r.underlying,
            hub: r.hub,
            assetId: r.assetId,
            decimals: r.decimals,
            collateralRisk: 0,
            flags: 0,
            dynamicConfigKey: 0
        });
    }

    /// @inheritdoc ISpoke
    function getReserveConfig(uint256 reserveId) external view returns (ReserveConfig memory) {
        return ReserveConfig({
            collateralRisk: 0,
            paused: false,
            frozen: false,
            borrowable: _reserves[reserveId].registered,
            receiveSharesEnabled: false
        });
    }

    /// @inheritdoc ISpoke
    /// @dev The mock keeps a single dynamic config (key 0) per reserve carrying its collateral factor.
    function getDynamicReserveConfig(uint256 reserveId, uint32)
        external
        view
        returns (DynamicReserveConfig memory)
    {
        return DynamicReserveConfig({
            collateralFactor: _reserves[reserveId].collateralFactorBps,
            maxLiquidationBonus: 10_500,
            liquidationFee: 1_000
        });
    }

    /// @notice Sets a user's collateral position directly (test helper).
    function seedSupplied(uint256 reserveId, address user, uint256 amount) external {
        _supplied[reserveId][user] = amount;
        _usingAsCollateral[reserveId][user] = true;
    }

    /// @notice Sets a user's debt position directly (test helper).
    function seedDebt(uint256 reserveId, address user, uint256 amount) external {
        _debt[reserveId][user] = amount;
    }

    /// @notice Whether a reserve is enabled as collateral for a user (test helper).
    function isUsingAsCollateral(uint256 reserveId, address user) external view returns (bool) {
        return _usingAsCollateral[reserveId][user];
    }
}

/// @notice Decimals accessor on an ERC-20, used to normalize balances into the USD base.
interface IERC20Decimals {
    function decimals() external view returns (uint8);
}
