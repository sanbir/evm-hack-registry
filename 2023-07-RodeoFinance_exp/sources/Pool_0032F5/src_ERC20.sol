// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

contract ERC20 {
    error InsufficientBalance();
    error InsufficientAllowance();

    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Approval(address indexed src, address indexed guy, uint256 amt);
    event Transfer(address indexed src, address indexed dst, uint256 amt);

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function transfer(address dst, uint256 amt) external returns (bool) {
        return transferFrom(msg.sender, dst, amt);
    }

    function transferFrom(address src, address dst, uint256 amt)
        public
        returns (bool)
    {
        if (balanceOf[src] < amt) revert InsufficientBalance();
        if (
            src != msg.sender && allowance[src][msg.sender] != type(uint256).max
        ) {
            if (allowance[src][msg.sender] < amt) revert InsufficientAllowance();
            allowance[src][msg.sender] = allowance[src][msg.sender] - amt;
        }
        balanceOf[src] = balanceOf[src] - amt;
        balanceOf[dst] = balanceOf[dst] + amt;
        emit Transfer(src, dst, amt);
        return true;
    }

    function approve(address usr, uint256 amt) external returns (bool) {
        allowance[msg.sender][usr] = amt;
        emit Approval(msg.sender, usr, amt);
        return true;
    }

    function _mint(address usr, uint256 amt) internal {
        balanceOf[usr] = balanceOf[usr] + amt;
        totalSupply = totalSupply + amt;
        emit Transfer(address(0), usr, amt);
    }

    function _burn(address usr, uint256 amt) internal {
        if (balanceOf[usr] < amt) revert InsufficientBalance();
        balanceOf[usr] = balanceOf[usr] - amt;
        totalSupply = totalSupply - amt;
        emit Transfer(usr, address(0), amt);
    }
}
