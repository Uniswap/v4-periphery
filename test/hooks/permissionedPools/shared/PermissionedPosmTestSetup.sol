// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {HookModifyLiquidities} from "../../../shared/HookModifyLiquidities.sol";
import {Deploy, IPositionDescriptor} from "../../../shared/Deploy.sol";
import {ERC721PermitHash} from "../../../../src/libraries/ERC721PermitHash.sol";
import {IWETH9} from "../../../../src/interfaces/external/IWETH9.sol";
import {LiquidityOperations} from "../../../shared/LiquidityOperations.sol";
import {PositionConfig} from "../../../shared/PositionConfig.sol";
import {PermissionedDeployers} from "./PermissionedDeployers.sol";
import {IPositionManager} from "../../../../src/interfaces/IPositionManager.sol";
import {Planner, Plan} from "../../../shared/Planner.sol";
import {ActionConstants} from "../../../../src/libraries/ActionConstants.sol";
import {Actions} from "../../../../src/libraries/Actions.sol";

struct BalanceInfo {
    uint256 balance0;
    uint256 balance1;
    uint256 balance0Manager;
    uint256 balance1Manager;
}

/// @notice A shared test contract that wraps the v4-core deployers contract and exposes basic liquidity operations on posm.
contract PermissionedPosmTestSetup is Test, PermissionedDeployers, DeployPermit2, LiquidityOperations {
    uint256 private constant STARTING_USER_BALANCE = 10_000_000 ether;
    address public constant GOVERNANCE = address(0xABCD);

    IAllowanceTransfer public permit2;
    IPositionDescriptor public positionDescriptor;
    TransparentUpgradeableProxy public proxy;
    IPositionDescriptor public proxyAsImplementation;
    HookModifyLiquidities public hookModifyLiquidities;
    Currency public currency2;
    IWETH9 public _WETH9;

    WETH public wethImpl = new WETH();

    PoolKey public wethKey;

    mapping(Currency => Currency) public wrappedToPermissioned;

    function deployAndApprovePosm(IPoolManager poolManager, address wrappedTokenFactory_, bytes32 salt) public {
        deployPermissionedPosm(poolManager, wrappedTokenFactory_, salt);
        approvePosm();
    }

    function deployPermissionedPosm(IPoolManager poolManager, address wrappedTokenFactory_, bytes32 salt) internal {
        permit2 = IAllowanceTransfer(deployPermit2());
        _WETH9 = deployWETH();
        proxyAsImplementation = deployDescriptor(poolManager, "ETH");
        lpm = Deploy.permissionedPositionManager(
            address(poolManager),
            address(permit2),
            100_000,
            address(proxyAsImplementation),
            address(_WETH9),
            wrappedTokenFactory_,
            abi.encode(salt)
        );
    }

    function deployAndApprovePosmOnly(IPoolManager poolManager, address wrappedTokenFactory_, bytes32 salt)
        public
        returns (IPositionManager secondaryPosm)
    {
        secondaryPosm = Deploy.permissionedPositionManager(
            address(poolManager),
            address(permit2),
            100_000,
            address(proxyAsImplementation),
            address(_WETH9),
            wrappedTokenFactory_,
            abi.encode(salt)
        );
        approvePosm();
    }

    function deployWETH() internal returns (IWETH9) {
        address wethAddr = makeAddr("WETH");
        vm.etch(wethAddr, address(wethImpl).code);
        return IWETH9(wethAddr);
    }

    function deployDescriptor(IPoolManager poolManager_, bytes32 label) internal returns (IPositionDescriptor) {
        positionDescriptor = Deploy.positionDescriptor(address(poolManager_), address(_WETH9), label, hex"00");
        proxy = Deploy.transparentUpgradeableProxy(address(positionDescriptor), GOVERNANCE, "", hex"03");
        return IPositionDescriptor(address(proxy));
    }

    function seedBalance(address to) internal {
        IERC20(Currency.unwrap(currency0)).transfer(to, STARTING_USER_BALANCE);
        IERC20(Currency.unwrap(currency1)).transfer(to, STARTING_USER_BALANCE);
        IERC20(Currency.unwrap(currency2)).transfer(to, STARTING_USER_BALANCE);
    }

    function approvePosm() internal {
        approvePosmCurrency(currency0);
        approvePosmCurrency(currency1);
        approvePosmCurrency(currency2);
    }

    function approvePosmCurrency(Currency currency) internal {
        // Because POSM uses permit2, we must execute 2 permits/approvals.
        // 1. First, the caller must approve permit2 on the token.
        IERC20(Currency.unwrap(currency)).approve(address(permit2), type(uint256).max);
        // 2. Then, the caller must approve POSM as a spender of permit2.
        permit2.approve(Currency.unwrap(currency), address(lpm), type(uint160).max, type(uint48).max);
    }

    // Does the same approvals as approvePosm, but for a specific address.
    /// @dev Should not be in a prank when calling this function
    function approvePosmFor(address addr) internal {
        vm.startPrank(addr);
        approvePosm();
        vm.stopPrank();
    }

    function getDigest(address spender, uint256 tokenId, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32 digest)
    {
        digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                lpm.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(ERC721PermitHash.PERMIT_TYPEHASH, spender, tokenId, nonce, deadline))
            )
        );
    }

    function getPermissionedCurrency(Currency currency) internal view returns (Currency) {
        Currency permissionedCurrency = wrappedToPermissioned[currency];
        if (permissionedCurrency == Currency.wrap(address(0))) {
            return currency;
        }
        return permissionedCurrency;
    }

    function setupContractBalance(PoolKey memory key, uint256 amount0ToTransfer, uint256 amount1ToTransfer) internal {
        getPermissionedCurrency(key.currency0).transfer(address(lpm), amount0ToTransfer);
        getPermissionedCurrency(key.currency1).transfer(address(lpm), amount1ToTransfer);

        assertEq(getPermissionedCurrency(key.currency0).balanceOf(address(lpm)), amount0ToTransfer);
        assertEq(getPermissionedCurrency(key.currency1).balanceOf(address(lpm)), amount1ToTransfer);
    }

    /// @dev This function is used to avoid stack-too-deep errors
    function getBalanceInfoSelfAndManager(PoolKey memory key) internal view returns (BalanceInfo memory) {
        return BalanceInfo({
            balance0: getPermissionedCurrency(key.currency0).balanceOfSelf(),
            balance1: getPermissionedCurrency(key.currency1).balanceOfSelf(),
            balance0Manager: key.currency0.balanceOf(address(manager)),
            balance1Manager: key.currency1.balanceOf(address(manager))
        });
    }

    /// @dev This function is used to avoid stack-too-deep errors
    function getBalanceInfo(PoolKey memory key) internal view returns (BalanceInfo memory) {
        return BalanceInfo({
            balance0: getPermissionedCurrency(key.currency0).balanceOf(address(lpm)),
            balance1: getPermissionedCurrency(key.currency1).balanceOf(address(lpm)),
            balance0Manager: key.currency0.balanceOf(address(manager)),
            balance1Manager: key.currency1.balanceOf(address(manager))
        });
    }

    function createMintPlan(PoolKey memory key, uint256 amount0ToTransfer, uint256 amount1ToTransfer)
        internal
        view
        returns (bytes memory)
    {
        int24 tickLower = -int24(key.tickSpacing);
        int24 tickUpper = int24(key.tickSpacing);
        uint256 liquidityToAdd = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0ToTransfer,
            amount1ToTransfer
        );

        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: tickLower, tickUpper: tickUpper});

        Plan memory planner = Planner.init();
        planner.add(
            Actions.MINT_POSITION,
            abi.encode(
                config.poolKey,
                config.tickLower,
                config.tickUpper,
                liquidityToAdd,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                address(this), // recipient
                ZERO_BYTES // hookData
            )
        );

        planner.add(Actions.SETTLE, abi.encode(key.currency0, ActionConstants.OPEN_DELTA, false));
        planner.add(Actions.SETTLE, abi.encode(key.currency1, ActionConstants.OPEN_DELTA, false));

        return planner.finalizeModifyLiquidityWithClose(config.poolKey);
    }

    function verifyMintResults(PoolKey memory key, BalanceInfo memory balanceInfoBefore, uint256 tokenId)
        internal
        view
    {
        uint256 balance0After = getPermissionedCurrency(key.currency0).balanceOf(address(lpm));
        uint256 balance1After = getPermissionedCurrency(key.currency1).balanceOf(address(lpm));
        uint256 balance0ManagerAfter = key.currency0.balanceOf(address(manager));
        uint256 balance1ManagerAfter = key.currency1.balanceOf(address(manager));
        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(tokenId, lpm.nextTokenId() - 1);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this));
        assertGt(balanceInfoBefore.balance0, balance0After);
        assertGt(balanceInfoBefore.balance1, balance1After);
        assertEq(balanceInfoBefore.balance0 - balance0After, balance0ManagerAfter - balanceInfoBefore.balance0Manager);
        assertEq(balanceInfoBefore.balance1 - balance1After, balance1ManagerAfter - balanceInfoBefore.balance1Manager);
        assertEq(
            liquidity,
            LiquidityAmounts.getLiquidityForAmounts(
                SQRT_PRICE_1_1,
                TickMath.getSqrtPriceAtTick(-int24(key.tickSpacing)),
                TickMath.getSqrtPriceAtTick(int24(key.tickSpacing)),
                100e18,
                100e18
            )
        );
    }
}
