// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/*
 * AuditVault 57534 — Magic Yearn MyStaking.claimableAmount (Zokyo, 2022-08).
 * unclaimedAmount is already stored net of fee. claimableAmount adds it to
 * the new accrual and applies the fee to the sum, so the same rewards are
 * commissioned a second time.
 */

contract MiniToken {
    string public name = "Reward";
    string public symbol = "RWD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MyStaking {
    uint256 public constant FEE_BPS = 1000;
    MiniToken public immutable reward;
    address public immutable feeTo;
    mapping(address => uint256) public unclaimedAmount;
    mapping(address => uint256) public pending;
    uint256 public lastFee;
    uint256 public lastPayout;

    constructor(MiniToken _reward, address _feeTo) {
        reward = _reward;
        feeTo = _feeTo;
    }

    function creditNet(address user, uint256 netAmount) external {
        unclaimedAmount[user] = netAmount;
    }

    function claimableAmount(address user) public view returns (uint256 payout, uint256 fee) {
        uint256 gross = unclaimedAmount[user] + pending[user];
        fee = gross * FEE_BPS / 10_000;
        payout = gross - fee;
    }

    function claim() external {
        (uint256 payout, uint256 fee) = claimableAmount(msg.sender);
        // @> VULN: fee is taken from unclaimedAmount that was already stored net of fee
        lastFee = fee;
        lastPayout = payout;
        unclaimedAmount[msg.sender] = 0;
        pending[msg.sender] = 0;
        if (fee > 0) reward.transfer(feeTo, fee);
        if (payout > 0) reward.transfer(msg.sender, payout);
    }
}

contract MyStakingFixed {
    MiniToken public immutable reward;
    address public immutable feeTo;
    mapping(address => uint256) public unclaimedAmount;
    uint256 public lastFee;
    uint256 public lastPayout;

    constructor(MiniToken _reward, address _feeTo) {
        reward = _reward;
        feeTo = _feeTo;
    }

    function creditNet(address user, uint256 netAmount) external {
        unclaimedAmount[user] = netAmount;
    }

    function claim() external {
        uint256 payout = unclaimedAmount[msg.sender];
        lastFee = 0;
        lastPayout = payout;
        unclaimedAmount[msg.sender] = 0;
        if (payout > 0) reward.transfer(msg.sender, payout);
    }
}

contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 public constant NET = 1000 ether;

    MiniToken public reward;
    MyStaking public staking;
    uint256 public feeTaken;
    uint256 public userGot;
    uint256 public extraFee;

    constructor() {
        reward = new MiniToken();
        staking = new MyStaking(reward, SINK);
    }

    function run() external {
        reward.mint(address(staking), NET);
        staking.creditNet(address(this), NET);
        uint256 storedNet = staking.unclaimedAmount(address(this));
        staking.claim();
        feeTaken = staking.lastFee();
        userGot = staking.lastPayout();
        extraFee = feeTaken;
        require(storedNet == NET, "net stored");
        require(feeTaken == 100 ether, "second fee");
        require(userGot == 900 ether, "user short");
        require(extraFee == 100 ether, "extra");
        require(reward.balanceOf(SINK) == 100 ether, "fee sink");
        require(reward.balanceOf(address(this)) == 900 ether, "user bal");
    }
}
