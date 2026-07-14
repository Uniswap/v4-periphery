// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/// @notice USDT-style approve-race ERC-20: a nonzero allowance cannot be changed to another nonzero value
///         (it must be zeroed first). Includes a test hook to force an allowance value, simulating a token
///         whose allowance degrades over time — a re-approve that isn't zero-first reverts here.
contract MockERC20ApproveRace {
    string public constant name = "ApproveRace";
    string public constant symbol = "RACE";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        require(amount == 0 || allowance[msg.sender][spender] == 0, "RACE: zero allowance first");
        allowance[msg.sender][spender] = amount;
        return true;
    }

    /// @dev test hook: force-set an allowance to simulate degradation without moving 2^256 tokens.
    function setAllowance(address owner, address spender, uint256 amount) external {
        allowance[owner][spender] = amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
