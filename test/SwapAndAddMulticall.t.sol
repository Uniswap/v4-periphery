// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {ISwapAndAdd} from "../src/interfaces/ISwapAndAdd.sol";
import {IPermit2Forwarder} from "../src/interfaces/IPermit2Forwarder.sol";
import {IUniversalRouter} from "../src/interfaces/external/IUniversalRouter.sol";
import {PositionConfig} from "./shared/PositionConfig.sol";
import {PosmTestSetup} from "./shared/PosmTestSetup.sol";

/// @notice Multicall on the zap (POSM-style `Multicall_v4`): the flagship flow is `[permitBatch, op]` — wire
///         the caller's Permit2 allowances from a signature and run the op in ONE transaction. The signer
///         deliberately holds NO standing Permit2 allowance toward the zap in these tests; only the one-time
///         token->Permit2 approval. Also pins the msg.value discipline under batching: the ops' exact
///         `msg.value == expected` checks plus balance-funded native spending make the classic multicall
///         double-spend impossible — a second native op reverts the whole batch.
contract SwapAndAddMulticallTest is PosmTestSetup {
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    bytes32 constant PERMIT_DETAILS_TYPEHASH =
        keccak256("PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)");
    bytes32 constant PERMIT_BATCH_TYPEHASH = keccak256(
        "PermitBatch(PermitDetails[] details,address spender,uint256 sigDeadline)PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)"
    );

    ISwapAndAdd zap;
    // `key` and `nativeKey` are inherited Deployers state, assigned in setUp

    address signer;
    uint256 signerPk;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        deployAndApprovePosm(manager);

        (key,) = initPool(currency0, currency1, IHooks(address(0)), 3000, int24(60), SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -600_000, tickUpper: 600_000, liquidityDelta: int256(1e24), salt: 0}),
            ""
        );
        (nativeKey,) = initPoolAndAddLiquidityETH(
            CurrencyLibrary.ADDRESS_ZERO, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1, 1 ether
        );

        zap = ISwapAndAdd(
            deployCode("SwapAndAdd.sol:SwapAndAdd", abi.encode(manager, permit2, lpm, IUniversalRouter(makeAddr("ur"))))
        );

        // the signer holds tokens and the one-time token->Permit2 approvals, but NO Permit2 allowance
        // naming the zap — the batched permit must supply that from the signature.
        (signer, signerPk) = makeAddrAndKey("signer");
        vm.deal(signer, 10 ether);
        MockERC20(Currency.unwrap(currency0)).mint(signer, 1e30);
        MockERC20(Currency.unwrap(currency1)).mint(signer, 1e30);
        vm.startPrank(signer);
        MockERC20(Currency.unwrap(currency0)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), type(uint256).max);
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
        vm.stopPrank();

        // the test contract keeps full allowances for POSM-side setup (minting positions to the signer)
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
    }

    // ─────────────────────────────── helpers ───────────────────────────────

    function _addParams(PoolKey memory k, uint256 a0, uint256 a1) internal view returns (ISwapAndAdd.AddParams memory) {
        return ISwapAndAdd.AddParams({
            poolKey: k,
            tickLower: -600,
            tickUpper: 600,
            amount0In: a0,
            amount1In: a1,
            route: "",
            routeFunding: new ISwapAndAdd.TokenAmount[](0),
            minLiquidity: 1,
            recipient: signer,
            hookData: "",
            deadline: block.timestamp + 1
        });
    }

    /// @dev PermitBatch naming the zap as spender over the given tokens, nonces read live from Permit2.
    function _batch(address[] memory tokens) internal view returns (IAllowanceTransfer.PermitBatch memory b) {
        IAllowanceTransfer.PermitDetails[] memory details = new IAllowanceTransfer.PermitDetails[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            (,, uint48 nonce) = permit2.allowance(signer, tokens[i], address(zap));
            details[i] = IAllowanceTransfer.PermitDetails({
                token: tokens[i], amount: type(uint160).max, expiration: type(uint48).max, nonce: nonce
            });
        }
        b = IAllowanceTransfer.PermitBatch({
            details: details, spender: address(zap), sigDeadline: block.timestamp + 100
        });
    }

    function _bothTokens() internal view returns (address[] memory tokens) {
        tokens = new address[](2);
        tokens[0] = Currency.unwrap(currency0);
        tokens[1] = Currency.unwrap(currency1);
    }

    function _oneToken(Currency c) internal pure returns (address[] memory tokens) {
        tokens = new address[](1);
        tokens[0] = Currency.unwrap(c);
    }

    function _sign(IAllowanceTransfer.PermitBatch memory b, uint256 pk) internal view returns (bytes memory) {
        bytes32[] memory detailHashes = new bytes32[](b.details.length);
        for (uint256 i = 0; i < b.details.length; i++) {
            detailHashes[i] = keccak256(abi.encode(PERMIT_DETAILS_TYPEHASH, b.details[i]));
        }
        bytes32 structHash = keccak256(
            abi.encode(PERMIT_BATCH_TYPEHASH, keccak256(abi.encodePacked(detailHashes)), b.spender, b.sigDeadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", permit2.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return bytes.concat(r, s, bytes1(v));
    }

    /// @dev `[permitBatch(tokens), <opCall>]` — the flagship single-tx approve-and-operate batch.
    function _permitThen(address[] memory tokens, bytes memory opCall) internal view returns (bytes[] memory calls) {
        IAllowanceTransfer.PermitBatch memory b = _batch(tokens);
        calls = new bytes[](2);
        calls[0] = abi.encodeCall(IPermit2Forwarder.permitBatch, (signer, b, _sign(b, signerPk)));
        calls[1] = opCall;
    }

    /// @dev Mint a plain POSM position owned by the signer (setup runs as the test contract).
    function _mintToSigner(PoolKey memory k, uint256 liquidity) internal returns (uint256 tokenId) {
        tokenId = lpm.nextTokenId();
        mint(PositionConfig({poolKey: k, tickLower: -600, tickUpper: 600}), liquidity, signer, "");
    }

    // ─────────────────────────────── happy paths ───────────────────────────────

    function test_multicall_permitThenAdd_withoutPriorAllowance() public {
        ISwapAndAdd.AddParams memory p = _addParams(key, 1e18, 2e18);
        bytes[] memory calls = _permitThen(_bothTokens(), abi.encodeCall(ISwapAndAdd.add, (p)));
        uint256 expectedId = lpm.nextTokenId();

        vm.prank(signer);
        bytes[] memory results = zap.multicall(calls);

        (uint256 tokenId, uint128 liquidity,,) = abi.decode(results[1], (uint256, uint128, uint256, uint256));
        assertEq(tokenId, expectedId, "returns the minted tokenId");
        assertGt(liquidity, 0, "position has liquidity");
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), signer, "NFT to the signer");
        assertEq(currency0.balanceOf(address(zap)), 0, "no token0 at rest");
        assertEq(currency1.balanceOf(address(zap)), 0, "no token1 at rest");
    }

    function test_multicall_permitThenIncrease_withoutPriorAllowance() public {
        uint256 tokenId = _mintToSigner(key, 1e21);
        uint128 before = lpm.getPositionLiquidity(tokenId);

        ISwapAndAdd.IncreaseParams memory p = ISwapAndAdd.IncreaseParams({
            tokenId: tokenId,
            amount0In: 1e18,
            amount1In: 1e18,
            route: "",
            routeFunding: new ISwapAndAdd.TokenAmount[](0),
            minLiquidityAdded: 1,
            recipient: signer,
            hookData: "",
            deadline: block.timestamp + 1
        });
        bytes[] memory calls = _permitThen(_bothTokens(), abi.encodeCall(ISwapAndAdd.increase, (p)));

        vm.prank(signer);
        bytes[] memory results = zap.multicall(calls);

        (uint128 added,,) = abi.decode(results[1], (uint128, uint256, uint256));
        assertGt(added, 0, "liquidity added");
        assertEq(lpm.getPositionLiquidity(tokenId), before + added, "position grew in place");
    }

    function test_multicall_permitThenRebalance_withoutPriorAllowance() public {
        uint256 tokenId = _mintToSigner(key, 1e21);

        ISwapAndAdd.RebalanceParams memory p = ISwapAndAdd.RebalanceParams({
            tokenId: tokenId,
            additional0: int128(1e18), // pulled via the batched permit — the part that needs the allowance
            additional1: 0,
            newTickLower: -1200,
            newTickUpper: 1200,
            route: "",
            routeFunding: new ISwapAndAdd.TokenAmount[](0),
            minLiquidity: 1,
            recipient: signer,
            hookData: "",
            deadline: block.timestamp + 1
        });
        bytes[] memory calls = _permitThen(_oneToken(currency0), abi.encodeCall(ISwapAndAdd.rebalance, (p)));
        uint256 expectedId = lpm.nextTokenId();

        vm.prank(signer);
        bytes[] memory results = zap.multicall(calls);

        (uint256 newTokenId, uint128 liquidity,,) = abi.decode(results[1], (uint256, uint128, uint256, uint256));
        assertEq(newTokenId, expectedId, "new position minted");
        assertGt(liquidity, 0, "new position has liquidity");
        assertEq(IERC721(address(lpm)).ownerOf(newTokenId), signer, "new NFT to the signer");
    }

    function test_multicall_permitThenAddNative_valueBatch() public {
        ISwapAndAdd.AddParams memory p = _addParams(nativeKey, 1e17, 1e17);
        // only currency1 needs a Permit2 allowance: currency0 is native and arrives as the batch's msg.value
        bytes[] memory calls = _permitThen(_oneToken(currency1), abi.encodeCall(ISwapAndAdd.add, (p)));
        uint256 expectedId = lpm.nextTokenId();

        vm.prank(signer);
        bytes[] memory results = zap.multicall{value: 1e17}(calls);

        (uint256 tokenId, uint128 liquidity,,) = abi.decode(results[1], (uint256, uint128, uint256, uint256));
        assertEq(tokenId, expectedId, "native-pool position minted");
        assertGt(liquidity, 0, "position has liquidity");
        assertEq(address(zap).balance, 0, "no native at rest");
    }

    /// @dev The operator-friendly composition: a zero-value batch of ERC20 ops over multiple positions. Every
    ///      op asserts msg.value == 0, so all-ERC20 batches compose freely; each op sweeps before returning.
    function test_multicall_zeroValueBatch_composesOps() public {
        uint256 id1 = _mintToSigner(key, 1e21);
        uint256 id2 = _mintToSigner(key, 1e21);
        // accrue fees on id2 so compound has something to reinvest
        vm.prank(signer);
        permit2.approve(Currency.unwrap(currency0), address(swapRouter), type(uint160).max, type(uint48).max);
        swap(key, true, -int256(1e20), "");
        swap(key, false, -int256(1e20), "");

        ISwapAndAdd.IncreaseParams memory inc = ISwapAndAdd.IncreaseParams({
            tokenId: id1,
            amount0In: 1e18,
            amount1In: 1e18,
            route: "",
            routeFunding: new ISwapAndAdd.TokenAmount[](0),
            minLiquidityAdded: 1,
            recipient: signer,
            hookData: "",
            deadline: block.timestamp + 1
        });
        ISwapAndAdd.CompoundParams memory comp = ISwapAndAdd.CompoundParams({
            tokenId: id2,
            route: "",
            minLiquidityAdded: 1,
            recipient: signer,
            hookData: "",
            deadline: block.timestamp + 1
        });

        IAllowanceTransfer.PermitBatch memory b = _batch(_bothTokens());
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(IPermit2Forwarder.permitBatch, (signer, b, _sign(b, signerPk)));
        calls[1] = abi.encodeCall(ISwapAndAdd.increase, (inc));
        calls[2] = abi.encodeCall(ISwapAndAdd.compound, (comp));

        uint128 liq1Before = lpm.getPositionLiquidity(id1);
        uint128 liq2Before = lpm.getPositionLiquidity(id2);

        vm.prank(signer);
        zap.multicall(calls);

        assertGt(lpm.getPositionLiquidity(id1), liq1Before, "increase ran");
        assertGt(lpm.getPositionLiquidity(id2), liq2Before, "compound ran");
        assertEq(currency0.balanceOf(address(zap)), 0, "no token0 at rest after the batch");
        assertEq(currency1.balanceOf(address(zap)), 0, "no token1 at rest after the batch");
    }

    // ─────────────────────────────── msg.value discipline ───────────────────────────────

    /// @dev THE classic multicall danger, pinned impossible: two native ops each asserting the same msg.value.
    ///      Both equality checks pass (delegatecall preserves msg.value), but native spending is BALANCE-
    ///      funded — the first op consumes and sweeps the value, the second finds an empty balance and the
    ///      whole batch reverts atomically. No double-spend, no partial execution.
    function test_multicall_secondNativeOp_cannotDoubleSpend() public {
        // signer has standing allowances here to isolate the value mechanics from the permit flow
        vm.startPrank(signer);
        permit2.approve(Currency.unwrap(currency1), address(zap), type(uint160).max, type(uint48).max);

        ISwapAndAdd.AddParams memory p = _addParams(nativeKey, 1e17, 1e17);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(ISwapAndAdd.add, (p));
        calls[1] = abi.encodeCall(ISwapAndAdd.add, (p));

        // the second op must fail CLEARLY (the balance guard in _pullBudget), not deep in the deploy
        vm.expectRevert(ISwapAndAdd.InvalidEthValue.selector);
        zap.multicall{value: 1e17}(calls);
        vm.stopPrank();
    }

    /// @dev An ERC20-only op asserts msg.value == 0, so it cannot ride in a value-bearing batch at all:
    ///      msg.value keeps exactly one meaning per batch.
    function test_multicall_erc20OpInValueBatch_reverts() public {
        vm.startPrank(signer);
        permit2.approve(Currency.unwrap(currency0), address(zap), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(zap), type(uint160).max, type(uint48).max);

        ISwapAndAdd.AddParams memory p = _addParams(key, 1e18, 2e18); // ERC20 pool: expected msg.value == 0
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(ISwapAndAdd.add, (p));

        vm.expectRevert(ISwapAndAdd.InvalidEthValue.selector);
        zap.multicall{value: 1}(calls);
        vm.stopPrank();
    }

    // ─────────────────────────────── failure & adversarial paths ───────────────────────────────

    /// @dev The permit signature is public in the mempool: anyone can submit it first (burning the nonce but
    ///      SETTING the allowance). The batched permit swallows that inner revert and the op completes.
    function test_multicall_frontRunPermit_stillSucceeds() public {
        ISwapAndAdd.AddParams memory p = _addParams(key, 1e18, 2e18);
        IAllowanceTransfer.PermitBatch memory b = _batch(_bothTokens());
        bytes memory sig = _sign(b, signerPk);

        // relayer front-runs the permit submission
        IPermit2Forwarder(address(zap)).permitBatch(signer, b, sig);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IPermit2Forwarder.permitBatch, (signer, b, sig));
        calls[1] = abi.encodeCall(ISwapAndAdd.add, (p));

        vm.prank(signer);
        bytes[] memory results = zap.multicall(calls);
        (, uint128 liquidity,,) = abi.decode(results[1], (uint256, uint128, uint256, uint256));
        assertGt(liquidity, 0, "op completes although the permit nonce was already burned");
    }

    /// @dev A garbage signature is swallowed by the forwarder; with no standing allowance the op's own Permit2
    ///      pull then reverts (fresh allowance slot -> expiration 0 -> AllowanceExpired), bubbled by multicall.
    function test_multicall_invalidSignature_revertsOnPull() public {
        ISwapAndAdd.AddParams memory p = _addParams(key, 1e18, 2e18);
        IAllowanceTransfer.PermitBatch memory b = _batch(_bothTokens());
        (, uint256 wrongPk) = makeAddrAndKey("not-the-signer");

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IPermit2Forwarder.permitBatch, (signer, b, _sign(b, wrongPk)));
        calls[1] = abi.encodeCall(ISwapAndAdd.add, (p));

        vm.prank(signer);
        vm.expectRevert(abi.encodeWithSelector(IAllowanceTransfer.AllowanceExpired.selector, 0));
        zap.multicall(calls);
    }

    // ─────────────────────────────── equivalence ───────────────────────────────

    /// @dev A batched `[permit, add]` must be observationally identical to granting the allowance and calling
    ///      `add` directly — same tokenId, same liquidity, same reported amounts (delegatecall preserves
    ///      msg.sender, so the pull and auth context are the caller's own either way).
    function testFuzz_multicall_permitThenAdd_matchesDirectCall(uint256 a0, uint256 a1) public {
        a0 = bound(a0, 0, 1e22);
        a1 = bound(a1, 0, 1e22);
        vm.assume(a0 + a1 > 1e6); // stay clear of the documented wei-scale dust regime

        ISwapAndAdd.AddParams memory p = _addParams(key, a0, a1);
        bytes[] memory calls = _permitThen(_bothTokens(), abi.encodeCall(ISwapAndAdd.add, (p)));

        // direct path: standing allowances + plain entrypoint
        uint256 snapshot = vm.snapshotState();
        vm.startPrank(signer);
        permit2.approve(Currency.unwrap(currency0), address(zap), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(zap), type(uint160).max, type(uint48).max);
        (uint256 dId, uint128 dLiq, uint256 dA0, uint256 dA1) = zap.add(p);
        vm.stopPrank();
        vm.revertToState(snapshot);

        // batched path: same params through [permitBatch, add]
        vm.prank(signer);
        bytes[] memory results = zap.multicall(calls);
        (uint256 wId, uint128 wLiq, uint256 wA0, uint256 wA1) =
            abi.decode(results[1], (uint256, uint128, uint256, uint256));

        assertEq(wId, dId, "same tokenId");
        assertEq(wLiq, dLiq, "same liquidity");
        assertEq(wA0, dA0, "same amount0");
        assertEq(wA1, dA1, "same amount1");
    }
}
