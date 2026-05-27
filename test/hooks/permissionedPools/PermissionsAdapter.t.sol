// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {
    IPermissionsAdapter,
    IAllowlistChecker
} from "../../../src/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {ERC20, IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PermissionedPoolsBase, MockAllowlistChecker} from "./PermissionedPoolsBase.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PermissionFlags, PermissionFlag} from "../../../src/hooks/permissionedPools/libraries/PermissionFlags.sol";

contract PermissionsAdapterTest is PermissionedPoolsBase {
    IPermissionsAdapter public permissionsAdapter;
    address public mockPoolManager;
    address public owner;

    function setUp() public override {
        super.setUp();
        mockPoolManager = makeAddr("mockPoolManager");
        owner = makeAddr("owner");
        bytes memory args = abi.encode(permissionedToken, mockPoolManager, owner, allowlistChecker);
        bytes memory initcode = abi.encodePacked(vm.getCode("PermissionsAdapter.sol:PermissionsAdapter"), args);
        assembly {
            sstore(permissionsAdapter.slot, create(0, add(initcode, 0x20), mload(initcode)))
        }
        permissionedToken.setTokenAllowlist(address(permissionsAdapter), true);
        vm.prank(owner);
        permissionsAdapter.updateAllowedWrapper(address(this), true);
    }

    function test_InitialState() public view {
        assertEq(IERC20Metadata(address(permissionsAdapter)).name(), "Uniswap v4 MockToken");
        assertEq(IERC20Metadata(address(permissionsAdapter)).symbol(), "v4MT");
        assertEq(IERC20Metadata(address(permissionsAdapter)).decimals(), permissionedToken.decimals());
        assertEq(permissionsAdapter.totalSupply(), 0);
        assertEq(permissionsAdapter.balanceOf(mockPoolManager), 0);
        assertEq(address(permissionsAdapter.allowListChecker()), address(allowlistChecker));
        assertEq(permissionsAdapter.POOL_MANAGER(), mockPoolManager);
        assertEq(address(permissionsAdapter.PERMISSIONED_TOKEN()), address(permissionedToken));
    }

    function testRevert_WhenNotOwner(address account) public {
        vm.assume(account != owner);
        vm.startPrank(account);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, account));
        permissionsAdapter.updateAllowedWrapper(account, true);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, account));
        permissionsAdapter.updateAllowListChecker(allowlistChecker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, account));
        permissionsAdapter.updateSwappingEnabled(true);
        vm.stopPrank();
    }

    function testRevert_WhenNotAllowedWrapper(address wrapper) public {
        vm.assume(wrapper != address(this));
        assertFalse(permissionsAdapter.allowedWrappers(wrapper));
        vm.prank(wrapper);
        vm.expectRevert(abi.encodeWithSelector(IPermissionsAdapter.UnauthorizedWrapper.selector, wrapper));
        permissionsAdapter.wrapToPoolManager(100);
    }

    function testRevert_WhenInsufficientBalance(uint256 amount, uint256 transferAmount) public {
        vm.assume(amount != 0);
        transferAmount = bound(amount, 0, amount - 1);
        permissionedToken.mint(address(permissionsAdapter), transferAmount);
        vm.expectRevert(
            abi.encodeWithSelector(IPermissionsAdapter.InsufficientBalance.selector, amount, transferAmount)
        );
        permissionsAdapter.wrapToPoolManager(amount);
    }

    function test_WrapToPoolManager(uint256 amount, uint256 actualAmount) public {
        actualAmount = bound(amount, amount, type(uint256).max);
        permissionedToken.mint(address(permissionsAdapter), actualAmount);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), mockPoolManager, amount);
        permissionsAdapter.wrapToPoolManager(amount);
        assertEq(permissionsAdapter.balanceOf(mockPoolManager), amount);
        assertEq(permissionedToken.balanceOf(mockPoolManager), actualAmount - amount);
    }

    function test_UpdateAllowedWrapper(address wrapper, bool allowed) public {
        vm.assume(wrapper != address(this));
        assertFalse(permissionsAdapter.allowedWrappers(wrapper));
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IPermissionsAdapter.AllowedWrapperUpdated(wrapper, allowed);
        permissionsAdapter.updateAllowedWrapper(wrapper, allowed);
        assertEq(permissionsAdapter.allowedWrappers(wrapper), allowed);
    }

    function testRevert_WhenNotSupportedInterfaceEOA(IAllowlistChecker newAllowListCheckerEOA) public {
        vm.assume(newAllowListCheckerEOA != allowlistChecker);
        vm.prank(owner);
        vm.expectRevert(); // expect revert without data
        permissionsAdapter.updateAllowListChecker(newAllowListCheckerEOA);
    }

    function testRevert_WhenNotSupportedInterfaceContract() public {
        IAllowlistChecker newAllowListCheckerContract = new ImproperAllowlistChecker();
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IPermissionsAdapter.InvalidAllowListChecker.selector, newAllowListCheckerContract)
        );
        permissionsAdapter.updateAllowListChecker(newAllowListCheckerContract);
    }

    /// @dev ERC-165 compliant contracts must return `false` for `0xffffffff`. A checker that returns
    ///      `true` for any interfaceId would bypass a direct `supportsInterface` check. The new
    ///      `ERC165Checker.supportsInterface` pre-check catches this.
    function testRevert_WhenBypassFakeSupportsInterface() public {
        IAllowlistChecker bypassChecker = new BypassAllowlistChecker();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IPermissionsAdapter.InvalidAllowListChecker.selector, bypassChecker));
        permissionsAdapter.updateAllowListChecker(bypassChecker);
    }

    function test_UpdateAllowListChecker() public {
        IAllowlistChecker newAllowListChecker = new MockAllowlistChecker();
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IPermissionsAdapter.AllowListCheckerUpdated(newAllowListChecker);
        permissionsAdapter.updateAllowListChecker(newAllowListChecker);
        assertEq(address(permissionsAdapter.allowListChecker()), address(newAllowListChecker));
    }

    function test_DepositForVerification(uint256 amount) public {
        address depositor = makeAddr("depositor");
        permissionedToken.setTokenAllowlist(depositor, true);
        permissionedToken.mint(depositor, amount);
        vm.startPrank(depositor);
        permissionedToken.approve(address(permissionsAdapter), amount);
        vm.expectEmit(true, true, true, true);
        emit IPermissionsAdapter.VerificationDeposit(depositor, amount);
        permissionsAdapter.depositForVerification(amount);
        vm.stopPrank();
        assertEq(permissionedToken.balanceOf(address(permissionsAdapter)), amount);
    }

    /// @dev USDT-style underlying tokens omit the bool return value on transferFrom. The raw
    ///      `transferFrom` call would revert when Solidity tries to decode bool from empty
    ///      returndata; `safeTransferFrom` accepts empty returndata as success.
    function test_DepositForVerification_NonReturningUnderlying() public {
        NonReturningToken usdtLike = new NonReturningToken();
        bytes memory args = abi.encode(IERC20(address(usdtLike)), mockPoolManager, owner, allowlistChecker);
        bytes memory initcode = abi.encodePacked(vm.getCode("PermissionsAdapter.sol:PermissionsAdapter"), args);
        address adapter;
        assembly {
            adapter := create(0, add(initcode, 0x20), mload(initcode))
        }

        address depositor = makeAddr("noReturnDepositor");
        uint256 amount = 1e18;
        usdtLike.mint(depositor, amount);
        vm.prank(depositor);
        usdtLike.approve(adapter, amount);

        vm.expectEmit(true, true, true, true);
        emit IPermissionsAdapter.VerificationDeposit(depositor, amount);
        vm.prank(depositor);
        IPermissionsAdapter(adapter).depositForVerification(amount);

        assertEq(usdtLike.balanceOf(adapter), amount);
    }

    function test_UpdateSwappingEnabled(bool enabled) public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IPermissionsAdapter.SwappingEnabledUpdated(enabled);
        permissionsAdapter.updateSwappingEnabled(enabled);
        assertEq(permissionsAdapter.swappingEnabled(), enabled);
    }

    function testRevert_WhenInvalidTransfer(address from, address to) public {
        vm.assume(from != address(0) && from != mockPoolManager);
        vm.assume(to != address(0) && to != mockPoolManager);
        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(IPermissionsAdapter.InvalidTransfer.selector, from, to));
        permissionsAdapter.transfer(to, 0);
    }

    function testRevert_PoolManagerSelfTransfer(uint256 mintAmount, uint256 transferAmount) public {
        // Cantina ECO-340: a TAKE(adapter, poolManager, ...) would otherwise unwrap raw underlying
        // back into the pool manager, breaking the adapter accounting boundary.
        transferAmount = bound(transferAmount, 0, mintAmount);
        permissionedToken.mint(address(permissionsAdapter), mintAmount);
        permissionsAdapter.wrapToPoolManager(mintAmount);

        vm.prank(mockPoolManager);
        vm.expectRevert(
            abi.encodeWithSelector(IPermissionsAdapter.InvalidTransfer.selector, mockPoolManager, mockPoolManager)
        );
        permissionsAdapter.transfer(mockPoolManager, transferAmount);

        // adapter and underlying state are unchanged
        assertEq(permissionsAdapter.balanceOf(mockPoolManager), mintAmount);
        assertEq(permissionedToken.balanceOf(mockPoolManager), 0);
        assertEq(permissionedToken.balanceOf(address(permissionsAdapter)), mintAmount);
    }

    function test_UnwrapOnPoolManagerTransfer(uint256 mintAmount, uint256 transferAmount, address recipient) public {
        vm.assume(recipient != address(0) && recipient != mockPoolManager && recipient != address(permissionsAdapter));
        assertEq(permissionedToken.balanceOf(recipient), 0);
        permissionedToken.setTokenAllowlist(recipient, true);
        transferAmount = bound(transferAmount, 0, mintAmount);
        permissionedToken.mint(address(permissionsAdapter), mintAmount);
        permissionsAdapter.wrapToPoolManager(mintAmount);
        vm.prank(mockPoolManager);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(mockPoolManager, recipient, transferAmount);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(recipient, address(0), transferAmount);
        permissionsAdapter.transfer(recipient, transferAmount);
        assertEq(permissionsAdapter.balanceOf(mockPoolManager), mintAmount - transferAmount);
        assertEq(permissionedToken.balanceOf(recipient), transferAmount);
    }

    function testRevert_UnwrapWhenUnderlyingReturnsFalse() public {
        FalseReturningToken falseToken = new FalseReturningToken();
        IPermissionsAdapter adapter = _deployAdapterForToken(IERC20(address(falseToken)));

        falseToken.mint(address(adapter), 100);
        adapter.wrapToPoolManager(100);

        address recipient = makeAddr("recipient");
        vm.prank(mockPoolManager);
        vm.expectRevert("TRANSFER_FAILED");
        IERC20(address(adapter)).transfer(recipient, 50);

        // Burn and payout are atomic: nothing moved.
        assertEq(adapter.totalSupply(), 100);
        assertEq(adapter.balanceOf(mockPoolManager), 100);
        assertEq(falseToken.balanceOf(recipient), 0);
    }

    function testRevert_UnwrapWhenUnderlyingPausedSilentFail() public {
        PausableSilentFailToken pausableToken = new PausableSilentFailToken();
        IPermissionsAdapter adapter = _deployAdapterForToken(IERC20(address(pausableToken)));

        pausableToken.mint(address(adapter), 100);
        adapter.wrapToPoolManager(100);
        pausableToken.pause();

        address recipient = makeAddr("recipient");
        vm.prank(mockPoolManager);
        vm.expectRevert("TRANSFER_FAILED");
        IERC20(address(adapter)).transfer(recipient, 50);

        assertEq(adapter.totalSupply(), 100);
        assertEq(adapter.balanceOf(mockPoolManager), 100);
        assertEq(pausableToken.balanceOf(recipient), 0);
        assertEq(pausableToken.balanceOf(address(adapter)), 100);
    }

    function test_UnwrapSucceedsAfterUnpause() public {
        PausableSilentFailToken pausableToken = new PausableSilentFailToken();
        IPermissionsAdapter adapter = _deployAdapterForToken(IERC20(address(pausableToken)));

        pausableToken.mint(address(adapter), 100);
        adapter.wrapToPoolManager(100);

        address recipient = makeAddr("recipient");
        vm.prank(mockPoolManager);
        IERC20(address(adapter)).transfer(recipient, 50);

        assertEq(adapter.totalSupply(), 50);
        assertEq(adapter.balanceOf(mockPoolManager), 50);
        assertEq(pausableToken.balanceOf(recipient), 50);
        assertEq(pausableToken.balanceOf(address(adapter)), 50);
    }

    // --- ERC20 metadata fallbacks ---

    function _assertMetadataFallbacks(IPermissionsAdapter adapter) internal view {
        assertEq(IERC20Metadata(address(adapter)).name(), "Uniswap v4 Permissioned Token");
        assertEq(IERC20Metadata(address(adapter)).symbol(), "v4PT");
        assertEq(IERC20Metadata(address(adapter)).decimals(), 18);
    }

    function test_Constructor_FallsBackWhenMetadataIsMissing() public {
        _assertMetadataFallbacks(_deployAdapterForToken(IERC20(address(new NoMetadataToken()))));
    }

    function test_Constructor_FallsBackWhenMetadataReverts() public {
        _assertMetadataFallbacks(_deployAdapterForToken(IERC20(address(new RevertingMetadataToken()))));
    }

    /// @dev bytes32 returns aren't standard ABI-encoded strings, so decode fails and we fall back.
    function test_Constructor_FallsBackOnBytes32Metadata() public {
        IPermissionsAdapter adapter = _deployAdapterForToken(IERC20(address(new Bytes32MetadataToken())));
        assertEq(IERC20Metadata(address(adapter)).name(), "Uniswap v4 Permissioned Token");
        assertEq(IERC20Metadata(address(adapter)).symbol(), "v4PT");
        // decimals() is a valid uint8 here, so it does NOT fall back.
        assertEq(IERC20Metadata(address(adapter)).decimals(), 18);
    }

    function test_Constructor_FallsBackWhenDecimalsDoesNotFitInUint8() public {
        IPermissionsAdapter adapter = _deployAdapterForToken(IERC20(address(new OversizedDecimalsToken())));
        // name/symbol decode cleanly.
        assertEq(IERC20Metadata(address(adapter)).name(), "Uniswap v4 Big");
        assertEq(IERC20Metadata(address(adapter)).symbol(), "v4BIG");
        // decimals decode as uint8 fails on the oversized value -> fallback.
        assertEq(IERC20Metadata(address(adapter)).decimals(), 18);
    }

    function _deployAdapterForToken(IERC20 token) internal returns (IPermissionsAdapter adapter) {
        bytes memory args = abi.encode(token, mockPoolManager, owner, allowlistChecker);
        bytes memory initcode = abi.encodePacked(vm.getCode("PermissionsAdapter.sol:PermissionsAdapter"), args);
        address deployed;
        assembly {
            deployed := create(0, add(initcode, 0x20), mload(initcode))
        }
        require(deployed != address(0), "deployment failed");
        adapter = IPermissionsAdapter(deployed);
        vm.prank(owner);
        adapter.updateAllowedWrapper(address(this), true);
    }
}

/// @dev ERC-20 that silently returns false from transfer without reverting or moving balances.
contract FalseReturningToken is ERC20 {
    constructor() ERC20("FalseToken", "FT") {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function transfer(address, uint256) public pure override returns (bool) {
        return false;
    }
}

/// @dev ERC-20 with pause logic that silently returns false on transfer when paused.
contract PausableSilentFailToken is ERC20 {
    bool public paused;

    constructor() ERC20("PausableToken", "PT") {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function pause() public {
        paused = true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (paused) return false;
        return super.transfer(to, amount);
    }
}

/// @dev Bare-minimum IERC20 so the mocks below do not inherit OZ ERC20 (which would auto-provide metadata).
abstract contract StubIERC20 is IERC20 {
    function totalSupply() external pure override returns (uint256) {
        return 0;
    }

    function balanceOf(address) external pure override returns (uint256) {
        return 0;
    }

    function transfer(address, uint256) external pure override returns (bool) {
        return true;
    }

    function allowance(address, address) external pure override returns (uint256) {
        return 0;
    }

    function approve(address, uint256) external pure override returns (bool) {
        return true;
    }

    function transferFrom(address, address, uint256) external pure override returns (bool) {
        return true;
    }
}

contract NoMetadataToken is StubIERC20 {}

contract RevertingMetadataToken is StubIERC20 {
    function name() external pure returns (string memory) {
        revert("no name");
    }

    function symbol() external pure returns (string memory) {
        revert("no symbol");
    }

    function decimals() external pure returns (uint8) {
        revert("no decimals");
    }
}

/// @dev Legacy MKR-style token that returns `bytes32` instead of `string` for name/symbol.
contract Bytes32MetadataToken is StubIERC20 {
    function name() external pure returns (bytes32) {
        return bytes32("MakerDAO");
    }

    function symbol() external pure returns (bytes32) {
        return bytes32("MKR");
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }
}

/// @dev `decimals()` returns a uint256 that does not fit in uint8 — ABI decode as uint8 must fail.
contract OversizedDecimalsToken is StubIERC20 {
    function name() external pure returns (string memory) {
        return "Big";
    }

    function symbol() external pure returns (string memory) {
        return "BIG";
    }

    function decimals() external pure returns (uint256) {
        return 999;
    }
}

contract ImproperAllowlistChecker is IAllowlistChecker {
    function checkAllowlist(address, address) public pure returns (PermissionFlag) {
        return PermissionFlags.ALL_ALLOWED;
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return false;
    }
}

/// @dev Returns `true` for every interfaceId, including `0xffffffff`. Defeats a naive direct
///      `supportsInterface` check; rejected by ERC-165's required pre-checks.
contract BypassAllowlistChecker is IAllowlistChecker {
    function checkAllowlist(address, address) public pure returns (PermissionFlag) {
        return PermissionFlags.ALL_ALLOWED;
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
}

/// @notice USDT-style ERC20: omits the bool return value on transfer/transferFrom. Used to confirm
///         that `PermissionsAdapter.depositForVerification` tolerates non-standard return shapes.
contract NonReturningToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    string public name = "NonReturning";
    string public symbol = "NORET";
    uint8 public decimals = 18;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        // intentionally no return value
    }

    function transferFrom(address from, address to, uint256 amount) external {
        require(allowance[from][msg.sender] >= amount, "allowance");
        require(balanceOf[from] >= amount, "balance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        // intentionally no return value
    }
}
