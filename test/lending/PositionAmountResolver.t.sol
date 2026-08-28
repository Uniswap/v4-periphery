// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {PositionAmountResolver} from "../../src/base/PositionAmountResolver.sol";
import {IAmountResolver} from "../../src/interfaces/IAmountResolver.sol";
import {Market} from "../../src/types/Market.sol";

/// @dev Minimal concrete resolver: serves a fixed position through the same public `positionOf`
///      surface the adapters expose, which the mixin reads with an internal call.
contract ResolverHarness is PositionAmountResolver {
    uint256 internal _collateral;
    uint256 internal _debt;
    bool internal _revertOnRead;

    function set(uint256 collateralAmount, uint256 debtAmount) external {
        _collateral = collateralAmount;
        _debt = debtAmount;
    }

    function setRevertOnRead(bool value) external {
        _revertOnRead = value;
    }

    function positionOf(address, Market memory) public view override returns (uint256, uint256) {
        require(!_revertOnRead, "MarketNotSupported");
        return (_collateral, _debt);
    }
}

contract PositionAmountResolverTest is Test {
    ResolverHarness internal resolver;

    address internal constant ACCOUNT = address(0xA11CE);
    Market internal market = Market({collateral: Currency.wrap(address(0xC0)), debt: Currency.wrap(address(0xD0))});

    function setUp() public {
        resolver = new ResolverHarness();
        resolver.set(3 ether, 1_500e6);
    }

    function _context(PositionAmountResolver.PositionAmount kind) internal view returns (bytes memory) {
        return abi.encode(kind, ACCOUNT, market);
    }

    function test_resolveAmount_debtReturnsLiveDebt() public view {
        assertEq(
            resolver.resolveAmount(_context(PositionAmountResolver.PositionAmount.DEBT)),
            1_500e6,
            "DEBT resolves the position's debt side"
        );
    }

    function test_resolveAmount_collateralReturnsLiveCollateral() public view {
        assertEq(
            resolver.resolveAmount(_context(PositionAmountResolver.PositionAmount.COLLATERAL)),
            3 ether,
            "COLLATERAL resolves the position's collateral side"
        );
    }

    /// @dev The consumer (a RESOLVE-capable Universal Router) invokes resolvers via STATICCALL;
    ///      the read path must be view-clean end to end.
    function test_resolveAmount_survivesStaticcall() public view {
        (bool ok, bytes memory data) = address(resolver)
            .staticcall(
                abi.encodeCall(IAmountResolver.resolveAmount, (_context(PositionAmountResolver.PositionAmount.DEBT)))
            );
        assertTrue(ok, "resolver readable under STATICCALL");
        assertEq(abi.decode(data, (uint256)), 1_500e6, "staticcall returns the resolved amount");
    }

    function test_resolveAmount_revertsOnMalformedContext() public {
        vm.expectRevert();
        resolver.resolveAmount(hex"deadbeef");
    }

    function test_resolveAmount_revertsOnOutOfRangeKind() public {
        // enum decoding rejects values above COLLATERAL
        bytes memory context = abi.encode(uint256(2), ACCOUNT, market);
        vm.expectRevert();
        resolver.resolveAmount(context);
    }

    function test_resolveAmount_propagatesPositionOfRevert() public {
        // an unrouted market reverts in positionOf (MarketNotSupported on the real adapters);
        // the resolver propagates rather than masking it with a zero amount
        resolver.setRevertOnRead(true);
        vm.expectRevert();
        resolver.resolveAmount(_context(PositionAmountResolver.PositionAmount.DEBT));
    }
}
