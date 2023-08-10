pragma solidity ^0.8.19;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {Owned} from "solmate/auth/Owned.sol";

contract UniswapV4ERC20 is ERC20, Owned {
    constructor(string memory name, string memory symbol) ERC20(name, symbol, 18) Owned(msg.sender) {}

    function mint(address account, uint256 amount) external onlyOwner {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external onlyOwner {
        _burn(account, amount);
    }
}
