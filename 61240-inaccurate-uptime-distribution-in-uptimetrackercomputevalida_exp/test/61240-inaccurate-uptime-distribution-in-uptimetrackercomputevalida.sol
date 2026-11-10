// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Suzaku UptimeTracker.computeValidatorUptime splits uptime across epochs
    the validator was not active in (Cyfrin, July 2025, finding 61240).
    SYNTHETIC, cheatcode-free reduction.
    The audited step is uptimeToDistribute / elapsedEpochs with no activity
    check. 100 seconds earned in the high-rate epoch are written as 50 and 50.
    Rates are 1 and 9 tokens per second. Paid is 500. Fair, attributing all
    100 seconds to the active epoch, is 900. The warp precompile is a local
    message reader. No timestamp warp. */

contract RewardToken {
    string public name = "Suzaku Reward";
    string public symbol = "RWD";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract UptimeMessage {
    function read() external pure returns (bytes32 validationId, uint256 uptime) {
        return (bytes32(uint256(1)), 100);
    }
}

contract UptimeTracker {
    uint256 public constant EPOCH = 100;
    bytes32 public constant VALIDATION_ID = bytes32(uint256(1));

    UptimeMessage public message;
    uint256 public checkpointTimestamp;
    mapping(uint48 epoch => uint256 uptime) public uptimeOf;

    constructor(UptimeMessage message_) {
        message = message_;
    }

    function seed(uint256 checkpointTs) external {
        checkpointTimestamp = checkpointTs;
    }

    /// @dev Floor so a replay timestamp below two epochs still has a pair of epochs.
    function epochNow() public view returns (uint48) {
        uint256 nowTs = block.timestamp < 2 * EPOCH ? 2 * EPOCH : block.timestamp;
        return uint48(nowTs / EPOCH);
    }

    function computeValidatorUptime() external {
        (bytes32 validationID, uint256 uptime) = message.read();
        require(validationID == VALIDATION_ID, "ID");

        uint48 currentEpoch = epochNow();
        uint256 currentEpochStart = uint256(currentEpoch) * EPOCH;
        uint48 lastUptimeEpoch = uint48(checkpointTimestamp / EPOCH);
        uint256 lastUptimeEpochStart = uint256(lastUptimeEpoch) * EPOCH;

        uint256 recordedUptime = uptime;
        uint256 elapsedEpochs = currentEpoch - lastUptimeEpoch;
        uint256 elapsedTime = currentEpochStart - lastUptimeEpochStart;
        uint256 remainingUptime = recordedUptime > elapsedTime ? recordedUptime - elapsedTime : 0;
        uint256 uptimeToDistribute = recordedUptime - remainingUptime;

        if (elapsedEpochs >= 1) {
            uint256 uptimePerEpoch = uptimeToDistribute / elapsedEpochs;
            for (uint48 i = 0; i < elapsedEpochs;) {
                uint48 epoch = lastUptimeEpoch + i;
                uptimeOf[epoch] = uptimePerEpoch; // @> VULN: even split stored, activity ignored
                unchecked {
                    i++;
                }
            }
        }
    }
}

/// @dev Same split, but only epochs the validator was active in receive uptime.
contract UptimeTrackerFixed {
    uint256 public constant EPOCH = 100;
    bytes32 public constant VALIDATION_ID = bytes32(uint256(1));

    UptimeMessage public message;
    uint256 public checkpointTimestamp;
    uint48 public activeEpoch;
    mapping(uint48 epoch => uint256 uptime) public uptimeOf;

    constructor(UptimeMessage message_, uint48 activeEpoch_) {
        message = message_;
        activeEpoch = activeEpoch_;
    }

    function seed(uint256 checkpointTs) external {
        checkpointTimestamp = checkpointTs;
    }

    function epochNow() public view returns (uint48) {
        uint256 nowTs = block.timestamp < 2 * EPOCH ? 2 * EPOCH : block.timestamp;
        return uint48(nowTs / EPOCH);
    }

    function computeValidatorUptime() external {
        (, uint256 uptime) = message.read();
        uint48 currentEpoch = epochNow();
        uint256 currentEpochStart = uint256(currentEpoch) * EPOCH;
        uint48 lastUptimeEpoch = uint48(checkpointTimestamp / EPOCH);
        uint256 lastUptimeEpochStart = uint256(lastUptimeEpoch) * EPOCH;
        uint256 elapsedEpochs = currentEpoch - lastUptimeEpoch;
        uint256 elapsedTime = currentEpochStart - lastUptimeEpochStart;
        uint256 remainingUptime = uptime > elapsedTime ? uptime - elapsedTime : 0;
        uint256 uptimeToDistribute = uptime - remainingUptime;

        uint256 activeCount;
        for (uint48 i = 0; i < elapsedEpochs;) {
            uint48 epoch = lastUptimeEpoch + i;
            if (epoch == activeEpoch) activeCount += 1;
            unchecked {
                i++;
            }
        }
        uint256 uptimePerEpoch = activeCount == 0 ? 0 : uptimeToDistribute / activeCount;
        for (uint48 i = 0; i < elapsedEpochs;) {
            uint48 epoch = lastUptimeEpoch + i;
            uptimeOf[epoch] = epoch == activeEpoch ? uptimePerEpoch : 0;
            unchecked {
                i++;
            }
        }
    }
}

contract Rewards {
    RewardToken public token;
    UptimeTracker public tracker;
    mapping(uint48 epoch => uint256 rate) public ratePerSecond;

    constructor(RewardToken token_, UptimeTracker tracker_) {
        token = token_;
        tracker = tracker_;
    }

    function setRate(uint48 epoch, uint256 rate) external {
        ratePerSecond[epoch] = rate;
    }

    function payout(uint48 fromEpoch, uint48 n) external returns (uint256 paid) {
        for (uint48 i = 0; i < n;) {
            uint48 epoch = fromEpoch + i;
            paid += tracker.uptimeOf(epoch) * ratePerSecond[epoch];
            unchecked {
                i++;
            }
        }
        require(token.transfer(msg.sender, paid), "PAY");
    }

    function fairAmount(uint256 uptimeSeconds, uint48 activeEpoch, uint48 fromEpoch, uint48 n)
        external
        view
        returns (uint256 fair)
    {
        uint256 activeCount;
        for (uint48 i = 0; i < n;) {
            if (fromEpoch + i == activeEpoch) activeCount += 1;
            unchecked {
                i++;
            }
        }
        uint256 per = activeCount == 0 ? 0 : uptimeSeconds / activeCount;
        for (uint48 i = 0; i < n;) {
            uint48 epoch = fromEpoch + i;
            if (epoch == activeEpoch) fair += per * ratePerSecond[epoch];
            unchecked {
                i++;
            }
        }
    }
}

contract Exploit {
    uint256 public constant LOW = 1 ether;
    uint256 public constant HIGH = 9 ether;

    RewardToken public token; // nonce 1
    UptimeMessage public message; // nonce 2
    UptimeTracker public tracker; // nonce 3
    Rewards public rewards; // nonce 4

    uint256 public paid;
    uint256 public fair;
    uint48 public lowEpoch;
    uint48 public highEpoch;

    constructor() {
        token = new RewardToken();
        message = new UptimeMessage();
        tracker = new UptimeTracker(message);
        rewards = new Rewards(token, tracker);
    }

    function run() external {
        uint48 currentEpoch = tracker.epochNow();
        lowEpoch = currentEpoch - 2;
        highEpoch = currentEpoch - 1;
        tracker.seed(uint256(lowEpoch) * tracker.EPOCH());
        rewards.setRate(lowEpoch, LOW);
        rewards.setRate(highEpoch, HIGH);
        token.mint(address(rewards), 900 ether);
        tracker.computeValidatorUptime();
        paid = rewards.payout(lowEpoch, 2);
        fair = rewards.fairAmount(100, highEpoch, lowEpoch, 2);
        require(tracker.uptimeOf(lowEpoch) == 50, "low uptime");
        require(tracker.uptimeOf(highEpoch) == 50, "high uptime");
        require(paid == 500 ether, "paid");
        require(fair == 900 ether, "fair");
        require(paid < fair, "not short");
        token.transfer(msg.sender, paid);
    }
}
