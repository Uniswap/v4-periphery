// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {PositionConfig} from "../../shared/PositionConfig.sol";
import {PermissionedPositionManagerTest} from "./PermissionedPositionManager.t.sol";
import {MockPermissionedToken, MockAllowlistChecker} from "./PermissionedPoolsBase.sol";
import {PermissionFlags} from "../../../src/hooks/permissionedPools/libraries/PermissionFlags.sol";
import {
    IPermissionsAdapter,
    IERC20 as IERC20Adapter
} from "../../../src/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";

/// @notice The LP's own "underlying" token for a PA they created and admin. `transfer` is UNCONDITIONAL: every
///         single call (not a one-shot "arm/disarm" trigger) burns gas down to a tiny floor and then reverts.
///         `transferFrom` is left untouched so setup (permit2 deposits, `depositForVerification`) still works —
///         only the `_unwrap` -> `safeTransfer` path exercised during delivery is malicious.
contract GasGuzzlerPermUnderlying is MockPermissionedToken {
    error Grief();

    /// @dev Small enough that the loop consumes essentially all forwarded gas, but leaves just enough for the
    ///      custom-error revert itself to complete without a raw "ran out of gas mid-opcode" halt.
    uint256 public constant FLOOR = 5_000;

    function transfer(address, uint256) public override returns (bool) {
        while (gasleft() > FLOOR) {} // burn ~everything forwarded to this call, unconditionally
        revert Grief();
    }
}

/// @title Gas-grief PoC for unwindPosition's per-currency delivery cascade and its fix
/// @dev The attacker is both the LP and the admin of their own PermissionsAdapter(s), so `_deliverCurrency`'s
///      `to = lp` then `to = admin` attempts both hit the malicious token's `transfer`. Before the fix each
///      attempt opened an uncapped `poolManager.unlock`, so EIP-150 63/64 forwarding let a griefed leg burn most
///      of the remaining gas; enough legs could starve later deliveries and the claim-handover fallback. After
///      the fix `_tryDeliverAsset` forwards at most `DELIVERY_GAS_LIMIT` per attempt, so each leg is bounded and
///      the fallback stays affordable; both scenarios below succeed at every gas level.
contract UnwindGasGriefPoC is PermissionedPositionManagerTest {
    /// @dev Deploys a malicious PA the attacker creates and admins themselves, wrapping `GasGuzzlerPermUnderlying`,
    ///      paired with the valid `permissionsAdapter0` (admin = address(this), the "honest compliance admin").
    ///      Redeploys until `paEvil < permissionsAdapter0` so the malicious currency is `currency0` and is
    ///      therefore delivered FIRST by `unwindPosition` — the worst case, since its own fallback + the entire
    ///      second currency's delivery must fit in whatever gas its two failed attempts leave behind.
    function _setupGasGriefPaPool()
        internal
        returns (uint256 tokenId, GasGuzzlerPermUnderlying malU, address paEvil, address evilLp)
    {
        evilLp = makeAddr("EVIL_LP_GASGRIEF");
        MockAllowlistChecker checker = new MockAllowlistChecker();

        while (true) {
            malU = new GasGuzzlerPermUnderlying();
            vm.prank(evilLp);
            address candidate =
                permissionsAdapterFactory.createPermissionsAdapter(IERC20Adapter(address(malU)), evilLp, checker);
            if (candidate < address(permissionsAdapter0)) {
                paEvil = candidate;
                break;
            }
        }

        _wireGriefPa(malU, paEvil, evilLp);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(paEvil),
            currency1: Currency.wrap(address(permissionsAdapter0)),
            fee: 3000,
            tickSpacing: 60,
            hooks: permissionedHooks
        });
        manager.initialize(key, SQRT_PRICE_1_1);

        // Fund + allowlist the LP on the valid adapter's underlying (malU already done above).
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(evilLp, PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency0)).mint(evilLp, 100 ether);
        malU.mint(evilLp, 100 ether);

        _approveViaPermit2(evilLp, Currency.unwrap(currency0));
        _approveViaPermit2(evilLp, address(malU));

        tokenId = lpm.nextTokenId();
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});
        vm.prank(evilLp);
        mint(config, 1e18, evilLp, ZERO_BYTES);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), evilLp);
    }

    /// @dev Stronger variant: BOTH currencies are LP-created, LP-admined malicious PAs wrapping independent
    ///      `GasGuzzlerPermUnderlying` tokens. This doubles the number of griefed `_tryDeliverAsset` attempts from
    ///      2 to 4 (LP+admin for currency0, then LP+admin for currency1), compounding the loss twice over instead
    ///      of once, with no benign currency left to "absorb" the deficit. Because admin0 == admin1 == evilLp
    ///      here, evilLp is the only possible caller (no honest third party to grief) — a worst-case calibration,
    ///      not a compliance-bypass scenario.
    function _setupDoubleGasGriefPaPool()
        internal
        returns (uint256 tokenId, address paEvilA, address paEvilB, address evilLp)
    {
        evilLp = makeAddr("EVIL_LP_GASGRIEF_2");
        MockAllowlistChecker checker = new MockAllowlistChecker();

        GasGuzzlerPermUnderlying malA;
        GasGuzzlerPermUnderlying malB;
        while (true) {
            malA = new GasGuzzlerPermUnderlying();
            malB = new GasGuzzlerPermUnderlying();
            vm.prank(evilLp);
            address candA =
                permissionsAdapterFactory.createPermissionsAdapter(IERC20Adapter(address(malA)), evilLp, checker);
            vm.prank(evilLp);
            address candB =
                permissionsAdapterFactory.createPermissionsAdapter(IERC20Adapter(address(malB)), evilLp, checker);
            if (candA < candB) {
                paEvilA = candA;
                paEvilB = candB;
                _wireGriefPa(malA, paEvilA, evilLp);
                _wireGriefPa(malB, paEvilB, evilLp);
                break;
            }
        }

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(paEvilA),
            currency1: Currency.wrap(paEvilB),
            fee: 3000,
            tickSpacing: 60,
            hooks: permissionedHooks
        });
        manager.initialize(key, SQRT_PRICE_1_1);

        malA.mint(evilLp, 100 ether);
        malB.mint(evilLp, 100 ether);
        _approveViaPermit2(evilLp, address(malA));
        _approveViaPermit2(evilLp, address(malB));

        tokenId = lpm.nextTokenId();
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});
        vm.prank(evilLp);
        mint(config, 1e18, evilLp, ZERO_BYTES);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), evilLp);
    }

    function _wireGriefPa(GasGuzzlerPermUnderlying malU, address paEvil, address evilLp) internal {
        // Everyone that will hold/receive malU must clear its allowlist (mock reverts on !isAllowed[to]).
        malU.setAllowlist(evilLp, PermissionFlags.ALL_ALLOWED);
        malU.setAllowlist(paEvil, PermissionFlags.ALL_ALLOWED);
        malU.setAllowlist(address(manager), PermissionFlags.ALL_ALLOWED);
        malU.setAllowlist(address(lpm), PermissionFlags.ALL_ALLOWED);

        malU.mint(paEvil, 1); // verification requires the adapter to hold a nonzero balance
        permissionsAdapterFactory.verifyPermissionsAdapter(paEvil);

        vm.prank(evilLp);
        IPermissionsAdapter(paEvil).updateAllowedHook(permissionedHooks, true);
        vm.prank(evilLp);
        IPermissionsAdapter(paEvil).updateAllowedWrapper(address(lpm), true);
    }

    function _approveViaPermit2(address who, address token) internal {
        vm.startPrank(who);
        IERC20(token).approve(address(permit2), type(uint256).max);
        (bool ok,) = address(permit2)
            .call(
                abi.encodeWithSignature(
                    "approve(address,address,uint160,uint48)", token, address(lpm), type(uint160).max, type(uint48).max
                )
            );
        require(ok);
        vm.stopPrank();
    }

    /// @notice Scenario A: ONE currency is the griefer, paired with an honest currency. Pre-fix this bricked at
    ///         5-10M and needed ~15M. Post-fix each attempt is capped at `DELIVERY_GAS_LIMIT`, so the grief is
    ///         bounded and a normal gas budget succeeds.
    function test_Fixed_singleCurrencyGrief_forceExitSucceedsAtNormalGas() public {
        (uint256 tokenId,, address paEvil, address evilLp) = _setupGasGriefPaPool();
        bytes memory callData = abi.encodeWithSelector(_UNWIND_SELECTOR, tokenId, uint128(0), uint128(0), bytes(""));

        uint256[3] memory gasLevels = [uint256(5_000_000), 10_000_000, 30_000_000];

        for (uint256 i = 0; i < gasLevels.length; i++) {
            uint256 g = gasLevels[i];
            uint256 snapshot = vm.snapshotState();
            (bool okLoop,) = address(lpm).call{gas: g}(callData);
            emit log_named_uint("gas supplied", g);
            emit log_named_string("unwindPosition succeeded?", okLoop ? "yes" : "no (reverted / bricked)");
            assertTrue(okLoop, "post-fix, unwindPosition must succeed at a normal gas budget");
            vm.revertToState(snapshot);
        }

        // Execute for real and confirm the LP is force-exited and the griefed leg landed as a 6909 claim.
        (bool ok,) = address(lpm).call{gas: 10_000_000}(callData);
        assertTrue(ok, "force-exit must succeed at a normal gas budget after the fix");

        vm.expectRevert();
        IERC721(address(lpm)).ownerOf(tokenId); // NFT burned -> LP removed, force-exit completed

        // paEvil's admin IS evilLp (the attacker admins their own adapter), so the griefed leg's fallback
        // claim lands on evilLp, not on the honest admin (address(this)) — it is not lost either way.
        assertGt(
            manager.balanceOf(evilLp, Currency.wrap(paEvil).toId()),
            0,
            "griefed leg must fall back to a 6909 claim, not be lost"
        );
    }

    /// @notice Scenario B: BOTH currencies are LP-admined griefers (4 griefed attempts). Pre-fix this bricked at
    ///         every gas level up to 1B. Post-fix the per-attempt cap bounds all four legs, so a normal gas budget
    ///         succeeds.
    function test_Fixed_doubleCurrencyGrief_forceExitSucceedsAtNormalGas() public {
        (uint256 tokenId,,, address evilLp) = _setupDoubleGasGriefPaPool();
        bytes memory callData = abi.encodeWithSelector(_UNWIND_SELECTOR, tokenId, uint128(0), uint128(0), bytes(""));

        uint256[3] memory gasLevels = [uint256(5_000_000), 10_000_000, 30_000_000];
        for (uint256 i = 0; i < gasLevels.length; i++) {
            uint256 g = gasLevels[i];
            uint256 snapshot = vm.snapshotState();
            vm.prank(evilLp);
            (bool okLoop,) = address(lpm).call{gas: g}(callData);
            emit log_named_uint("gas supplied", g);
            emit log_named_string("unwindPosition succeeded?", okLoop ? "yes" : "no (reverted / bricked)");
            assertTrue(okLoop, "post-fix, unwindPosition must succeed at a normal gas budget (even the self-dos case)");
            vm.revertToState(snapshot);
        }

        vm.prank(evilLp);
        (bool ok,) = address(lpm).call{gas: 10_000_000}(callData);
        assertTrue(ok, "force-exit must succeed at a normal gas budget after the fix, even with 4 griefed legs");

        vm.expectRevert();
        IERC721(address(lpm)).ownerOf(tokenId); // NFT burned -> LP removed, force-exit completed
    }
}
