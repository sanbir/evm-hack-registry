// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  KittenSwap Voter — killGauge deletes claimable rewards
    (Pashov Audit Group, KittenSwap 2025-05-07, finding 58013 / H-02).
    SYNTHETIC, cheatcode-free. killGauge is the audited function (@> VULN).

    notifyRewardAmount accrues index from totalWeight. _updateFor adds the
    gauge's share to claimable while the gauge is alive. killGauge then
    sets claimable to 0. The 1,000 that was claimable becomes unclaimable.
    reviveGauge turns the gauge back on and does not restore the amount.
    The reward tokens stay in the Voter.

    The control pays the accrued claimable to the staker as part of
    deactivation, so the same 1,000 is received instead of deleted. */

contract RewardToken {
    string public name = "Kitten";
    string public symbol = "KITTEN";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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

contract Gauge {}

contract Voter {
    address public emergencyCouncil;
    address public base;
    uint256 public index;
    uint256 public totalWeight;
    mapping(address => bool) public isAlive;
    mapping(address => uint256) public claimable;
    mapping(address => uint256) public supplyIndex;
    mapping(address => uint256) public weights;

    constructor(address _base) {
        base = _base;
        emergencyCouncil = msg.sender;
    }

    function addGauge(address _gauge, uint256 weight) external {
        require(!isAlive[_gauge], "exists");
        isAlive[_gauge] = true;
        weights[_gauge] = weight;
        totalWeight += weight;
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        RewardToken(token).transferFrom(from, to, amount);
    }

    function notifyRewardAmount(uint amount) external {
        _safeTransferFrom(base, msg.sender, address(this), amount);
        uint256 _ratio = (amount * 1e18) / totalWeight;
        if (_ratio > 0) {
            index += _ratio;
        }
    }

    function updateFor(address _gauge) external {
        uint256 _supplied = weights[_gauge];
        uint256 _supplyIndex = supplyIndex[_gauge];
        uint256 _index = index;
        supplyIndex[_gauge] = _index;
        uint _delta = _index - _supplyIndex;
        if (_delta > 0) {
            uint _share = (uint(_supplied) * _delta) / 1e18;
            if (isAlive[_gauge]) {
                claimable[_gauge] += _share;
            }
        }
    }

    function killGauge(address _gauge) external {
        require(msg.sender == emergencyCouncil, "not emergency council");
        require(isAlive[_gauge], "gauge already dead");
        isAlive[_gauge] = false;
        // @> VULN: accrued claimable rewards are deleted. claim pays 0, and revive does not put them back.
        claimable[_gauge] = 0;
    }

    function reviveGauge(address _gauge) external {
        require(msg.sender == emergencyCouncil, "not emergency council");
        require(!isAlive[_gauge], "alive");
        isAlive[_gauge] = true;
    }

    function claim(address _gauge, address to) external returns (uint256 amount) {
        amount = claimable[_gauge];
        if (amount > 0) {
            claimable[_gauge] = 0;
            RewardToken(base).transfer(to, amount);
        }
    }
}

contract Exploit {
    uint256 public constant REWARD = 1000e18;
    uint256 public constant WEIGHT = 1000e18;
    address public constant STAKER = 0x000000000000000000000000000000000000bEEF;

    RewardToken public token; // nonce 1
    Voter public voter; // nonce 2
    Gauge public gauge; // nonce 3

    uint256 public claimableBefore;
    uint256 public claimableAfter;
    uint256 public paid;
    uint256 public stuck;

    constructor() {
        token = new RewardToken();
        voter = new Voter(address(token));
        gauge = new Gauge();
        token.mint(address(this), REWARD);
    }

    function run() external {
        require(token.balanceOf(STAKER) == 0, "staker already paid");
        token.approve(address(voter), REWARD);
        voter.addGauge(address(gauge), WEIGHT);

        voter.notifyRewardAmount(REWARD);
        voter.updateFor(address(gauge));
        claimableBefore = voter.claimable(address(gauge));
        require(claimableBefore == REWARD, "not accrued");

        voter.killGauge(address(gauge));
        claimableAfter = voter.claimable(address(gauge));
        require(claimableAfter == 0, "claimable survived");
        require(voter.isAlive(address(gauge)) == false, "still alive");

        paid = voter.claim(address(gauge), STAKER);
        require(paid == 0, "claim paid");
        require(token.balanceOf(STAKER) == 0, "staker received rewards");

        voter.reviveGauge(address(gauge));
        require(voter.isAlive(address(gauge)), "not revived");
        require(voter.claimable(address(gauge)) == 0, "revive restored rewards");

        stuck = token.balanceOf(address(voter));
        require(stuck == REWARD, "rewards left the voter");
    }
}
