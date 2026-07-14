// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/// @notice ERC-20 that hardcodes an infinite allowance for the canonical Permit2 ("Permit2-native" token
///         pattern) and reverts approve() toward it — such approvals are pointless and strict implementations
///         disallow them. Integrations must therefore neither trust the token's ERC20 allowance as proof of
///         their own wiring (their Permit2-internal grants may not exist yet) nor issue the redundant approve.
contract MockERC20Permit2Native {
    string public constant name = "Permit2Native";
    string public constant symbol = "P2N";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    address public immutable permit2;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) private _allowance;

    constructor(address _permit2) {
        permit2 = _permit2;
    }

    function allowance(address owner, address spender) public view returns (uint256) {
        if (spender == permit2) return type(uint256).max;
        return _allowance[owner][spender];
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        require(spender != permit2, "P2N: permit2 allowance is hardcoded");
        _allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance(from, msg.sender);
        if (allowed != type(uint256).max) _allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
