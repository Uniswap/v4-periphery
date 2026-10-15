// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";

import {Planner, Plan} from "../../shared/Planner.sol";
import {Actions} from "../../../src/libraries/Actions.sol";
import {ActionConstants} from "../../../src/libraries/ActionConstants.sol";
import {PermissionedPositionManagerTest} from "./PermissionedPositionManager.t.sol";
import {MockPermissionedToken, MockAllowlistChecker} from "./PermissionedPoolsBase.sol";
import {PermissionFlags} from "../../../src/hooks/permissionedPools/libraries/PermissionFlags.sol";
import {
    IPermissionsAdapter,
    IERC20 as IERC20Adapter
} from "../../../src/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";

/// @notice Contract-wallet LP whose receive() strands a PoolManager delta (native-ETH reentrancy).
contract MaliciousNativeLP {
    IPoolManager public immutable manager;
    bool public armed;

    constructor(IPoolManager _m) {
        manager = _m;
    }

    function arm(bool a) external {
        armed = a;
    }

    function exec(address t, uint256 v, bytes calldata d) external returns (bytes memory) {
        (bool ok, bytes memory ret) = t.call{value: v}(d);
        require(ok, "exec");
        return ret;
    }

    receive() external payable {
        if (armed) {
            armed = false;
            manager.mint(address(this), 0, 1); // strand a global delta mid-unlock, only when armed
        }
    }
}

/// @notice Contract-wallet LP whose receive() burns nearly all forwarded gas then reverts.
///         The native take reverts, so delivery is caught and the LP falls back to an ETH 6909 claim.
contract GasGriefingLP {
    function exec(address t, uint256 v, bytes calldata d) external returns (bytes memory) {
        (bool ok, bytes memory ret) = t.call{value: v}(d);
        require(ok, "exec");
        return ret;
    }

    receive() external payable {
        // Burn a full block's worth of gas (the realistic per-call cap), then revert.
        uint256 g = gasleft();
        uint256 target = g > 30_000_000 ? g - 30_000_000 : g / 2;
        while (gasleft() > target) {}
        revert("griefed");
    }
}

/// @notice LP-supplied ERC20 whose transfer reenters PoolManager.mint to strand a delta (finding note 1).
contract MaliciousPairedToken {
    string public name = "MAL";
    string public symbol = "MAL";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    IPoolManager public immutable manager;
    bool public armed;

    constructor(IPoolManager _m) {
        manager = _m;
    }

    function arm(bool a) external {
        armed = a;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
        totalSupply += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        return _x(msg.sender, to, a);
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= a;
        return _x(f, to, a);
    }

    function _x(address f, address to, uint256 a) internal returns (bool) {
        if (armed) {
            armed = false;
            manager.mint(address(this), 0, 1); // strand a global delta mid-unlock, only when armed
        }
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// @notice A permissioned token the LP controls: it satisfies the adapter's allowlist path (via MockPermissionedToken)
///         but strands a PoolManager delta on transfer when armed. Wrapped in a verified PA the LP admins, this is
///         the "malicious PA" case: the adapter unwrap during delivery runs this token's reentrant transfer.
contract MaliciousPermUnderlying is MockPermissionedToken {
    IPoolManager public immutable mgr;
    bool public armed;

    constructor(IPoolManager _m) {
        mgr = _m;
    }

    function arm(bool a) external {
        armed = a;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _grief();
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _grief();
        return super.transferFrom(from, to, amount);
    }

    function _grief() internal {
        if (armed) {
            armed = false;
            mgr.mint(address(this), 0, 1); // strand a global delta mid-unlock, only when armed
        }
    }
}

contract UnwindReentrancyFixedPoC is PermissionedPositionManagerTest {
    using Planner for Plan;

    function _mintPosition(PoolKey memory key, address owner, uint256 ethValue) internal returns (uint256 tokenId) {
        int24 tl = -60;
        int24 tu = 60;
        uint256 liq = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1, TickMath.getSqrtPriceAtTick(tl), TickMath.getSqrtPriceAtTick(tu), 1 ether, 1 ether
        );
        Plan memory p = Planner.init();
        p.add(
            Actions.MINT_POSITION, abi.encode(key, tl, tu, liq, type(uint128).max, type(uint128).max, owner, bytes(""))
        );
        p.add(Actions.CLOSE_CURRENCY, abi.encode(key.currency0));
        p.add(Actions.CLOSE_CURRENCY, abi.encode(key.currency1));
        if (ethValue > 0) p.add(Actions.SWEEP, abi.encode(Currency.wrap(address(0)), owner));
        tokenId = lpm.nextTokenId();
        bytes memory calls = p.encode();
        if (owner.code.length > 0) {
            MaliciousNativeLP(payable(owner))
                .exec(
                    address(lpm),
                    ethValue,
                    abi.encodeWithSelector(lpm.modifyLiquidities.selector, calls, block.timestamp + 1)
                );
        } else {
            vm.prank(owner);
            lpm.modifyLiquidities{value: ethValue}(calls, block.timestamp + 1);
        }
    }

    function _approveAsContract(address who, address token) internal {
        MaliciousNativeLP(payable(who))
            .exec(token, 0, abi.encodeWithSelector(IERC20.approve.selector, address(permit2), type(uint256).max));
        MaliciousNativeLP(payable(who))
            .exec(
                address(permit2),
                0,
                abi.encodeWithSignature(
                    "approve(address,address,uint160,uint48)", token, address(lpm), type(uint160).max, type(uint48).max
                )
            );
    }

    // 1. Native pool + malicious contract-wallet LP: force-exit SUCCEEDS; LP gets an ETH 6909 claim.
    function test_forceExit_succeeds_vs_native_contract_LP_griefer() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(permissionsAdapter0)),
            fee: 3000,
            tickSpacing: 60,
            hooks: permissionedHooks
        });
        manager.initialize(key, SQRT_PRICE_1_1);

        MaliciousNativeLP lp = new MaliciousNativeLP(manager);
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(address(lp), PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency0)).mint(address(lp), 100 ether);
        vm.deal(address(lp), 100 ether);
        _approveAsContract(address(lp), Currency.unwrap(currency0));

        uint256 tokenId = _mintPosition(key, address(lp), 1 ether);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(lp));

        lp.arm(true); // its receive() will try to strand a delta when handed ETH
        (bool ok,) =
            address(lpm).call(abi.encodeWithSelector(_UNWIND_SELECTOR, tokenId, uint128(0), uint128(0), bytes("")));
        assertTrue(ok, "force-exit must succeed despite native reentrancy");

        vm.expectRevert();
        IERC721(address(lpm)).ownerOf(tokenId); // NFT burned -> LP removed
        assertGt(manager.balanceOf(address(lp), 0), 0, "griefer LP was handed an ETH 6909 claim instead of real ETH");
    }

    // 2. LP pairs the permissioned token with their OWN malicious ERC20: force-exit SUCCEEDS.
    function test_forceExit_succeeds_vs_malicious_paired_token() public {
        MaliciousPairedToken mal = new MaliciousPairedToken(manager);
        (Currency c0, Currency c1) = address(permissionsAdapter0) < address(mal)
            ? (Currency.wrap(address(permissionsAdapter0)), Currency.wrap(address(mal)))
            : (Currency.wrap(address(mal)), Currency.wrap(address(permissionsAdapter0)));
        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: permissionedHooks});
        manager.initialize(key, SQRT_PRICE_1_1);

        MockPermissionedToken(Currency.unwrap(currency0)).mint(alice, 100 ether);
        mal.mint(alice, 100 ether);
        vm.startPrank(alice);
        IERC20(Currency.unwrap(currency0)).approve(address(permit2), type(uint256).max);
        (bool a0,) = address(permit2)
            .call(
                abi.encodeWithSignature(
                    "approve(address,address,uint160,uint48)",
                    Currency.unwrap(currency0),
                    address(lpm),
                    type(uint160).max,
                    type(uint48).max
                )
            );
        require(a0);
        IERC20(address(mal)).approve(address(permit2), type(uint256).max);
        (bool a1,) = address(permit2)
            .call(
                abi.encodeWithSignature(
                    "approve(address,address,uint160,uint48)",
                    address(mal),
                    address(lpm),
                    type(uint160).max,
                    type(uint48).max
                )
            );
        require(a1);
        vm.stopPrank();

        uint256 tokenId = _mintPosition(key, alice, 0);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), alice);

        mal.arm(true);
        (bool ok,) =
            address(lpm).call(abi.encodeWithSelector(_UNWIND_SELECTOR, tokenId, uint128(0), uint128(0), bytes("")));
        assertTrue(ok, "force-exit must succeed despite malicious paired token");

        vm.expectRevert();
        IERC721(address(lpm)).ownerOf(tokenId);
        assertGt(
            manager.balanceOf(alice, Currency.wrap(address(mal)).toId()),
            0,
            "LP handed a claim of their own malicious token"
        );
    }

    // 3. Benign EOA LP in a native pool gets REAL ETH, not a claim.
    function test_forceExit_delivers_real_ETH_to_benign_EOA_LP() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(permissionsAdapter0)),
            fee: 3000,
            tickSpacing: 60,
            hooks: permissionedHooks
        });
        manager.initialize(key, SQRT_PRICE_1_1);

        vm.deal(alice, 100 ether);
        uint256 tokenId = _mintPosition(key, alice, 1 ether);

        uint256 ethBefore = alice.balance;
        (bool ok,) =
            address(lpm).call(abi.encodeWithSelector(_UNWIND_SELECTOR, tokenId, uint128(0), uint128(0), bytes("")));
        assertTrue(ok, "force-exit should succeed for a benign EOA");
        assertGt(alice.balance, ethBefore, "benign EOA LP received real ETH");
        assertEq(manager.balanceOf(alice, 0), 0, "no ETH claim minted for the benign case");
    }

    /// @notice Builds a pool pairing the valid adapter0 with an LP-created, LP-admined PA that wraps a
    ///         malicious permissioned token, then mints a position owned by the LP. `lpm` is allowed to
    ///         wrap the evil PA. Returns the position and the pieces callers arm or mutate.
    function _setupMaliciousPaPool()
        internal
        returns (uint256 tokenId, MaliciousPermUnderlying malU, address paEvil, address evilLp)
    {
        evilLp = makeAddr("EVIL_LP");
        MockAllowlistChecker checker = new MockAllowlistChecker();

        // The LP creates and verifies a PA wrapping their own malicious permissioned token, as its admin.
        malU = new MaliciousPermUnderlying(manager);
        vm.prank(evilLp);
        paEvil = permissionsAdapterFactory.createPermissionsAdapter(IERC20Adapter(address(malU)), evilLp, checker);

        // Everyone that will hold/receive malU must be on its token allowlist (mock reverts on !isAllowed[to]).
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

        (Currency c0, Currency c1) = address(permissionsAdapter0) < paEvil
            ? (Currency.wrap(address(permissionsAdapter0)), Currency.wrap(paEvil))
            : (Currency.wrap(paEvil), Currency.wrap(address(permissionsAdapter0)));
        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: permissionedHooks});
        manager.initialize(key, SQRT_PRICE_1_1);

        // Fund + allowlist the LP on the valid adapter's underlying, and on malU (already done above).
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(evilLp, PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency0)).mint(evilLp, 100 ether);
        malU.mint(evilLp, 100 ether);

        vm.startPrank(evilLp);
        IERC20(Currency.unwrap(currency0)).approve(address(permit2), type(uint256).max);
        (bool a0,) = address(permit2)
            .call(
                abi.encodeWithSignature(
                    "approve(address,address,uint160,uint48)",
                    Currency.unwrap(currency0),
                    address(lpm),
                    type(uint160).max,
                    type(uint48).max
                )
            );
        require(a0);
        IERC20(address(malU)).approve(address(permit2), type(uint256).max);
        (bool a1,) = address(permit2)
            .call(
                abi.encodeWithSignature(
                    "approve(address,address,uint160,uint48)",
                    address(malU),
                    address(lpm),
                    type(uint160).max,
                    type(uint48).max
                )
            );
        require(a1);
        vm.stopPrank();

        tokenId = _mintPosition(key, evilLp, 0);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), evilLp);
    }

    // 4. LP pairs the valid PA with ANOTHER PA they created and admin, wrapping their own malicious token.
    //    The adapter unwrap during delivery runs the malicious token; the force-exit must still succeed.
    function test_forceExit_succeeds_vs_LP_admined_malicious_PA() public {
        (uint256 tokenId, MaliciousPermUnderlying malU,,) = _setupMaliciousPaPool();

        malU.arm(true); // its transfer during the adapter unwrap will strand a delta

        // address(this) is admin of the valid adapter0, so it is authorized to force-exit.
        (bool ok,) =
            address(lpm).call(abi.encodeWithSelector(_UNWIND_SELECTOR, tokenId, uint128(0), uint128(0), bytes("")));
        assertTrue(ok, "force-exit must succeed vs an LP-admined malicious PA");
        vm.expectRevert();
        IERC721(address(lpm)).ownerOf(tokenId);
    }

    // 5. LP revokes lpm from their evil PA's allowedWrappers after minting. allowedWrappers is checked only in
    //    the wrap direction, so the force-exit (which unwraps) is unaffected and still succeeds.
    function test_forceExit_survives_removed_allowedWrappers() public {
        (uint256 tokenId, MaliciousPermUnderlying malU, address paEvil, address evilLp) = _setupMaliciousPaPool();

        // The LP strips PermPosm (lpm) from allowedWrappers after minting. A UR entry would be revoked the same
        // way, but this base wires no UR, so revoking lpm is the meaningful case. allowedWrappers gates only the
        // wrap direction, so this cannot brick the unwind.
        vm.prank(evilLp);
        IPermissionsAdapter(paEvil).updateAllowedWrapper(address(lpm), false);

        malU.arm(true);
        (bool ok,) =
            address(lpm).call(abi.encodeWithSelector(_UNWIND_SELECTOR, tokenId, uint128(0), uint128(0), bytes("")));
        assertTrue(ok, "force-exit must succeed even after allowedWrappers is revoked (wrap-only gate)");
        vm.expectRevert();
        IERC721(address(lpm)).ownerOf(tokenId);
    }

    // 6. Contract-wallet LP in a native pool whose receive() burns nearly all forwarded gas then reverts.
    //    The native take is caught by the try/catch and the LP falls back to an ETH 6909 claim.
    function test_forceExit_survives_gas_griefing_native_LP() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(permissionsAdapter0)),
            fee: 3000,
            tickSpacing: 60,
            hooks: permissionedHooks
        });
        manager.initialize(key, SQRT_PRICE_1_1);

        GasGriefingLP lp = new GasGriefingLP();
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(address(lp), PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency0)).mint(address(lp), 100 ether);
        vm.deal(address(lp), 100 ether);
        _approveAsContract(address(lp), Currency.unwrap(currency0));

        uint256 tokenId = _mintPosition(key, address(lp), 1 ether);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(lp));

        (bool ok,) =
            address(lpm).call(abi.encodeWithSelector(_UNWIND_SELECTOR, tokenId, uint128(0), uint128(0), bytes("")));
        assertTrue(ok, "force-exit must succeed despite a gas-griefing receive()");

        vm.expectRevert();
        IERC721(address(lpm)).ownerOf(tokenId);
        assertGt(manager.balanceOf(address(lp), 0), 0, "gas-griefer LP was handed an ETH 6909 claim");
    }
}
