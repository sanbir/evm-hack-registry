// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Regnum Aurum — H-01 (Pashov, 2026-03-21)
    _updateReward advances lastProcessedDistributionIndex by the count of
    distributions that happen to be fully claimed inside the window, not by
    the contiguous completed prefix. A 1-epoch stream finishing beside a
    4-epoch stream pushes the cursor past the unfinished older stream.
    At timestamp 1, D0 vests 1 of 4 epochs and D1 vests its only epoch.
    The cursor moves to 1. D0's remaining 300 tokens can never be scanned.
*/

contract Token {
    string public symbol = "RWD";
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
}

contract RewardStream {
    uint40 internal constant WEEK = 7 days;
    uint256 internal constant MAX_DISTRIBUTIONS = 10;

    struct Distribution {
        uint40 epochs;
        uint32 startTimestamp;
        uint256 eligible;
    }

    Token public token;
    Distribution[] public distributions;
    mapping(address => uint32) public lastProcessedDistributionIndex;
    mapping(address => mapping(uint256 => uint40)) public epochsClaimed;

    constructor(Token _token) {
        token = _token;
    }

    function addDistribution(uint40 epochs, uint32 startTimestamp, uint256 eligible) external {
        distributions.push(Distribution(epochs, startTimestamp, eligible));
    }

    function distributionCount() external view returns (uint256) {
        return distributions.length;
    }

    function _getClaimableAmount(uint256 eligibleRewards, uint40 epochs, uint32 startTimestamp, uint40 cachedEpochsClaimed)
        internal
        view
        returns (uint256 claimableAmount, uint40 epochsClaimedNow)
    {
        uint40 currentEpoch = uint40(((block.timestamp - startTimestamp) / WEEK) + 1);
        if (currentEpoch >= epochs) currentEpoch = epochs;
        uint256 claimablePerEpoch = eligibleRewards / epochs;
        for (uint40 i = cachedEpochsClaimed; i < currentEpoch; i++) {
            claimableAmount += claimablePerEpoch;
            epochsClaimedNow++;
        }
        return (claimableAmount, cachedEpochsClaimed + epochsClaimedNow);
    }

    function _scan(address user, uint256 startIndex) internal returns (uint256 paid, uint256 processed) {
        uint256 totalDistributions = distributions.length;
        uint256 processDistributions = startIndex + MAX_DISTRIBUTIONS;
        if (processDistributions > totalDistributions) processDistributions = totalDistributions;
        for (uint256 i = startIndex; i < processDistributions; i++) {
            uint40 claimed = epochsClaimed[user][i];
            uint40 totalEpochs = distributions[i].epochs;
            if (claimed >= totalEpochs) {
                processed += 1;
                continue;
            }
            (uint256 claimableAmount, uint40 newClaimed) = _getClaimableAmount(
                distributions[i].eligible, totalEpochs, distributions[i].startTimestamp, claimed
            );
            epochsClaimed[user][i] = newClaimed;
            if (claimableAmount > 0) {
                paid += claimableAmount;
                require(token.transfer(user, claimableAmount), "pay");
            }
            if (newClaimed >= totalEpochs) {
                processed += 1;
            }
        }
    }

    function updateReward(address user) external virtual returns (uint256 paid) {
        uint256 startIndex = lastProcessedDistributionIndex[user];
        uint256 processed;
        (paid, processed) = _scan(user, startIndex);
        // @> VULN: processed counts every finished distribution in the window, so a later 1-epoch stream advances the cursor past an older unfinished stream
        lastProcessedDistributionIndex[user] = uint32(startIndex + processed);
    }

    function claimable(address user) public view returns (uint256 total) {
        uint256 startIndex = lastProcessedDistributionIndex[user];
        uint256 totalDistributions = distributions.length;
        for (uint256 i = startIndex; i < totalDistributions; i++) {
            uint40 claimed = epochsClaimed[user][i];
            uint40 totalEpochs = distributions[i].epochs;
            if (claimed >= totalEpochs) continue;
            (uint256 amt,) = _preview(distributions[i], claimed);
            total += amt;
        }
    }

    function stranded(address user) public view returns (uint256 total) {
        uint256 cursor = lastProcessedDistributionIndex[user];
        for (uint256 i = 0; i < cursor; i++) {
            uint40 claimed = epochsClaimed[user][i];
            uint40 epochs = distributions[i].epochs;
            if (claimed < epochs) {
                total += (distributions[i].eligible / epochs) * (epochs - claimed);
            }
        }
    }

    function _preview(Distribution memory d, uint40 cached) internal view returns (uint256 claimableAmount, uint40) {
        return _getClaimableAmount(d.eligible, d.epochs, d.startTimestamp, cached);
    }
}

contract RewardStreamFixed is RewardStream {
    constructor(Token _token) RewardStream(_token) {}

    function updateReward(address user) external override returns (uint256 paid) {
        uint256 startIndex = lastProcessedDistributionIndex[user];
        uint256 totalDistributions = distributions.length;
        uint256 processDistributions = startIndex + MAX_DISTRIBUTIONS;
        if (processDistributions > totalDistributions) processDistributions = totalDistributions;
        uint256 prefix;
        bool gap;
        for (uint256 i = startIndex; i < processDistributions; i++) {
            uint40 claimed = epochsClaimed[user][i];
            uint40 totalEpochs = distributions[i].epochs;
            if (claimed < totalEpochs) {
                (uint256 claimableAmount, uint40 newClaimed) = _getClaimableAmount(
                    distributions[i].eligible, totalEpochs, distributions[i].startTimestamp, claimed
                );
                epochsClaimed[user][i] = newClaimed;
                if (claimableAmount > 0) {
                    paid += claimableAmount;
                    require(token.transfer(user, claimableAmount), "pay");
                }
                if (newClaimed < totalEpochs) gap = true;
            }
            if (!gap && epochsClaimed[user][i] >= totalEpochs) {
                prefix += 1;
            }
        }
        lastProcessedDistributionIndex[user] = uint32(startIndex + prefix);
    }
}

contract Exploit {
    uint256 public constant D0 = 400 ether;
    uint256 public constant D1 = 100 ether;
    uint256 public constant STRANDED = 300 ether;

    Token public token;
    RewardStream public stream;
    uint256 public paid;
    uint256 public locked;

    constructor() {
        token = new Token();
        stream = new RewardStream(token);
    }

    function run() external {
        token.mint(address(stream), D0 + D1);
        stream.addDistribution(4, 0, D0);
        stream.addDistribution(1, 0, D1);
        require(stream.distributionCount() == 2, "queued");

        paid = stream.updateReward(address(this));
        require(paid == 200 ether, "vested now");
        require(stream.epochsClaimed(address(this), 0) == 1, "d0 partial");
        require(stream.epochsClaimed(address(this), 1) == 1, "d1 done");
        require(stream.lastProcessedDistributionIndex(address(this)) == 1, "cursor skipped");

        uint256 beforeSecond = token.balanceOf(address(this));
        uint256 second = stream.updateReward(address(this));
        locked = token.balanceOf(address(stream));

        require(second == 0, "second paid");
        require(token.balanceOf(address(this)) == beforeSecond, "extra pay");
        require(stream.lastProcessedDistributionIndex(address(this)) == 2, "cursor kept moving");
        require(stream.claimable(address(this)) == 0, "still visible");
        require(stream.stranded(address(this)) == STRANDED, "stranded");
        require(locked == STRANDED, "locked");
    }
}
