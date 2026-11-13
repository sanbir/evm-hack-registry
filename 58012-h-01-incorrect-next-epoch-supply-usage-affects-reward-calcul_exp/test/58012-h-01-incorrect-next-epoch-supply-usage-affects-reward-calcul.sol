// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  KittenSwap ExternalBribe — previous-epoch supply is read at the next epoch
    (Pashov, KittenSwap, 2025-05, H-01). Same line in Velodrome's bribe.
    SYNTHETIC, cheatcode-free. The audited assignment is verbatim (@> VULN).

    Epoch supply was 100 while this voter held 100. At the boundary the supply
    checkpoint becomes 1_000. getPriorSupplyIndex(_nextEpochStart + DURATION)
    returns that next checkpoint, so a 1_000 reward pays 100 instead of 1_000.
    900 stays in the bribe. */

contract RewardToken {
    string public name = "KITTEN";
    string public symbol = "KITTEN";
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

contract ExternalBribe {
    uint256 public constant DURATION = 7 days;

    struct Checkpoint {
        uint256 timestamp;
        uint256 supply;
    }

    struct Prev {
        uint256 _prevSupply;
    }

    RewardToken public rewardToken;
    Checkpoint[] public supplyCheckpoints;
    uint256 public supplyNumCheckpoints;
    uint256 public epochReward;
    uint256 public voterBalance;
    bool public useFixedIndex;

    constructor(RewardToken rewardToken_) {
        rewardToken = rewardToken_;
    }

    function getPriorSupplyIndex(uint256 timestamp) public view returns (uint256) {
        uint256 nCheckpoints = supplyNumCheckpoints;
        if (nCheckpoints == 0) return 0;
        if (supplyCheckpoints[nCheckpoints - 1].timestamp <= timestamp) {
            return nCheckpoints - 1;
        }
        if (supplyCheckpoints[0].timestamp > timestamp) return 0;
        uint256 lower = 0;
        uint256 upper = nCheckpoints - 1;
        while (upper > lower) {
            uint256 center = upper - (upper - lower) / 2;
            Checkpoint memory cp = supplyCheckpoints[center];
            if (cp.timestamp == timestamp) {
                return center;
            } else if (cp.timestamp < timestamp) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return lower;
    }

    function writeSupply(uint256 timestamp, uint256 supply) external {
        supplyCheckpoints.push(Checkpoint({timestamp: timestamp, supply: supply}));
        supplyNumCheckpoints = supplyCheckpoints.length;
    }

    function setVoter(uint256 balance, uint256 pot) external {
        voterBalance = balance;
        epochReward = pot;
    }

    function _supplyAt(uint256 _nextEpochStart) internal view virtual returns (uint256) {
        Prev memory _prev;
        // @> VULN: _nextEpochStart + DURATION is the next epoch, not the one being paid
        _prev._prevSupply = supplyCheckpoints[getPriorSupplyIndex(_nextEpochStart + DURATION)].supply;
        return _prev._prevSupply;
    }

    function earned(uint256 _nextEpochStart) public view returns (uint256) {
        uint256 supply = _supplyAt(_nextEpochStart);
        return voterBalance * epochReward / supply;
    }

    function getReward(uint256 _nextEpochStart) external virtual returns (uint256 paid) {
        paid = earned(_nextEpochStart);
        rewardToken.transfer(msg.sender, paid);
    }
}

contract ExternalBribeFixed is ExternalBribe {
    constructor(RewardToken rewardToken_) ExternalBribe(rewardToken_) {}

    function _supplyAt(uint256 _nextEpochStart) internal view override returns (uint256) {
        return supplyCheckpoints[getPriorSupplyIndex(_nextEpochStart + DURATION - 1)].supply;
    }
}

contract Exploit {
    uint256 public constant POT = 1000 ether;
    uint256 public constant BUGGY_PAY = 100 ether;
    uint256 public constant FAIR_PAY = 1000 ether;
    uint256 public constant KEPT = 900 ether;
    uint256 public constant EPOCH_START = 1;

    RewardToken public kitten; // nonce 1
    ExternalBribe public bribe; // nonce 2

    uint256 public paid;
    uint256 public fair;
    uint256 public kept;
    uint256 public usedSupply;

    constructor() {
        kitten = new RewardToken();
        bribe = new ExternalBribe(kitten);
    }

    function run() external {
        bribe.writeSupply(EPOCH_START, 100);
        bribe.writeSupply(EPOCH_START + 7 days, 1000);
        bribe.setVoter(100, POT);
        kitten.mint(address(bribe), POT);
        usedSupply = bribe.getPriorSupplyIndex(EPOCH_START + 7 days);
        fair = 100 * POT / 100;
        paid = bribe.getReward(EPOCH_START);
        kept = kitten.balanceOf(address(bribe));
        require(usedSupply == 1, "index is the next checkpoint");
        require(paid == BUGGY_PAY, "paid 100");
        require(fair == FAIR_PAY, "fair 1000");
        require(kept == KEPT, "900 stays");
        require(kitten.balanceOf(address(this)) == BUGGY_PAY, "voter got 100");
    }
}
