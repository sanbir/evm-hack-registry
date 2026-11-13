// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  CoreDAO PledgeAgent.distributePowerReward — the round coin term is the
    delegated amount only. Undelegated coins are left out of
    rs.coin * POWER_BLOCK_FACTOR * powerFactor / 10000 * totalReward / score
    (Halborn, Genesis, PledgeAgent.sol L204).
    SYNTHETIC, cheatcode-free.
    Delegated coin = 100, undelegated = 50, totalReward = 1,000, score = 1,000.
    The buggy path pays the miner 100 CORE. The control adds the 50 and pays 150.
    The 50 CORE gap stays in the agent. */

contract Core {
    string public symbol = "CORE";
    uint8 public decimals = 18;
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

contract Harm {
    string public symbol = "SHORT";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract Miner {}

contract PledgeAgent {
    uint256 public constant POWER_BLOCK_FACTOR = 1;
    Core public core;
    uint256 public rsCoin;
    uint256 public undelegatedCoin;
    uint256 public powerFactor;
    uint256 public totalReward;
    uint256 public score;
    uint256 public remainReward;
    mapping(address => uint256) public rewardMap;

    constructor(address _core) {
        core = Core(_core);
    }

    function seed(uint256 coin, uint256 undelegated, uint256 factor, uint256 reward, uint256 _score) external {
        rsCoin = coin;
        undelegatedCoin = undelegated;
        powerFactor = factor;
        totalReward = reward;
        score = _score;
        remainReward = reward;
        core.mint(address(this), reward);
    }

    function distributePowerReward(address miner) external returns (uint256 reward) {
        // @> VULN: rs.coin is delegated only; undelegatedCoin is not in the product
        reward = rsCoin * POWER_BLOCK_FACTOR * powerFactor / 10000 * totalReward / score;
        uint256 minerSize = 1;
        uint256 paid = reward * minerSize;
        require(remainReward >= paid, "there is not enough reward");
        rewardMap[miner] += reward;
        remainReward -= paid;
        core.transfer(miner, reward);
    }
}

contract FixedAgent {
    uint256 public constant POWER_BLOCK_FACTOR = 1;
    Core public core;
    uint256 public rsCoin;
    uint256 public undelegatedCoin;
    uint256 public powerFactor;
    uint256 public totalReward;
    uint256 public score;
    uint256 public remainReward;

    constructor(address _core) {
        core = Core(_core);
    }

    function seed(uint256 coin, uint256 undelegated, uint256 factor, uint256 reward, uint256 _score) external {
        rsCoin = coin;
        undelegatedCoin = undelegated;
        powerFactor = factor;
        totalReward = reward;
        score = _score;
        remainReward = reward;
        core.mint(address(this), reward);
    }

    function distributePowerReward(address miner) external returns (uint256 reward) {
        uint256 coin = rsCoin + undelegatedCoin;
        reward = coin * POWER_BLOCK_FACTOR * powerFactor / 10000 * totalReward / score;
        require(remainReward >= reward, "there is not enough reward");
        remainReward -= reward;
        core.transfer(miner, reward);
    }
}

contract Exploit {
    uint256 public constant COIN = 100;
    uint256 public constant UNDELEGATED = 50;
    uint256 public constant FACTOR = 10000;
    uint256 public constant REWARD = 1000 ether;
    uint256 public constant SCORE = 1000;
    address public constant SINK = 0x000000000000000000000000000000000000D00d;

    Harm public harm;
    Core public core;
    PledgeAgent public buggy;
    FixedAgent public fixedAgent;
    Miner public miner;
    Miner public controlMiner;

    uint256 public paid;
    uint256 public controlPaid;
    uint256 public shortfall;
    uint256 public leftInAgent;

    constructor() {
        harm = new Harm();
        core = new Core();
        buggy = new PledgeAgent(address(core));
        fixedAgent = new FixedAgent(address(core));
        miner = new Miner();
        controlMiner = new Miner();
        buggy.seed(COIN, UNDELEGATED, FACTOR, REWARD, SCORE);
        fixedAgent.seed(COIN, UNDELEGATED, FACTOR, REWARD, SCORE);
    }

    function run() external {
        require(buggy.undelegatedCoin() == UNDELEGATED, "undelegated");
        require(buggy.rsCoin() == COIN, "delegated");
        paid = buggy.distributePowerReward(address(miner));
        require(paid == 100 ether, "underpaid");
        require(core.balanceOf(address(miner)) == 100 ether, "miner");
        leftInAgent = core.balanceOf(address(buggy));
        require(leftInAgent == 900 ether, "stuck share");
        controlPaid = fixedAgent.distributePowerReward(address(controlMiner));
        require(controlPaid == 150 ether, "control");
        require(core.balanceOf(address(controlMiner)) == 150 ether, "control miner");
        shortfall = controlPaid - paid;
        require(shortfall == 50 ether, "gap");
        harm.mint(SINK, shortfall);
        require(harm.balanceOf(SINK) == 50 ether, "marked");
    }
}
