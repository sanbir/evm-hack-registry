// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Recall — [H-07] Incorrect loop indexing in LibAddressStakingReleases.compact()
    (Code4rena 2025-02-recall; #65094)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: compact() uses while (i < length) where i = startIdx (absolute
    index into releases[]) but length is the *count* of pending releases. After
    the first compaction sets startIdx=100 and length=15, the next call starts
    with i=100 and immediately fails i < 15 — claimable collateral never
    releases; validator funds lock forever.
    Blamed while condition preserved (@> VULN).
    Source: code-423n4/2025-02-recall@ab5f90b9 contracts/lib/LibStaking.sol */

struct StakingRelease {
    uint256 releaseAt;
    uint256 amount;
}

struct AddressStakingReleases {
    // mapping index → release (absolute indices grow forever)
    mapping(uint16 => StakingRelease) releases;
    uint16 length; // pending count
    uint16 startIdx; // absolute index of first pending
}

/// @dev Reduced LibAddressStakingReleases as a contract (library storage pattern).
contract StakingReleaseQueue {
    AddressStakingReleases private self;
    MockToken public token;
    mapping(address => uint256) public claimablePaid;

    constructor(MockToken t) {
        token = t;
    }

    function push(uint256 releaseAt, uint256 amount) external {
        uint16 length = self.length;
        uint16 nextIdx = self.startIdx + length;
        self.releases[nextIdx] = StakingRelease({releaseAt: releaseAt, amount: amount});
        self.length = length + 1;
    }

    /// @notice Perform compaction on releases — VERBATIM loop bug from LibStaking.sol
    function compact() public returns (uint256, uint16) {
        uint16 length = self.length;
        if (self.length == 0) {
            revert("NoCollateralToWithdraw");
        }

        uint16 i = self.startIdx;

        uint16 newLength = length;
        uint256 amount;
        while (i < length) { // @> VULN: compares absolute index i (startIdx) with pending count length — when startIdx >= length loop never runs
            // FIX: while (i < self.startIdx + self.length)  OR while (processed < length && ...)
            StakingRelease memory release = self.releases[i];

            // releases are ordered ascending by releaseAt, no need to check
            // further as they will still be locked.
            if (release.releaseAt > block.number) {
                break;
            }

            amount += release.amount;
            delete self.releases[i];

            unchecked {
                ++i;
                --newLength;
            }
        }

        self.startIdx = i;
        self.length = newLength;

        return (amount, newLength);
    }

    function claim(address validator) external returns (uint256 amount) {
        (amount, ) = compact();
        if (amount > 0) {
            token.mint(validator, amount); // simulate transfer of released collateral
            claimablePaid[validator] += amount;
        }
    }

    function startIdx() external view returns (uint16) {
        return self.startIdx;
    }

    function pendingLength() external view returns (uint16) {
        return self.length;
    }

    function releaseAt(uint16 idx) external view returns (uint256) {
        return self.releases[idx].releaseAt;
    }

    function releaseAmount(uint16 idx) external view returns (uint256) {
        return self.releases[idx].amount;
    }

    /// @dev Test helper: fast-forward absolute index state as after a large compaction history.
    function setState(uint16 start, uint16 len) external {
        self.startIdx = start;
        self.length = len;
    }

    function writeRelease(uint16 idx, uint256 releaseAt_, uint256 amount_) external {
        self.releases[idx] = StakingRelease({releaseAt: releaseAt_, amount: amount_});
    }
}

contract MockToken {
    string public name = "Collateral";
    string public symbol = "COL";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract Exploit {
    MockToken public token; // CREATE 1
    StakingReleaseQueue public queue; // CREATE 2

    uint256 public constant LOCKED = 15 ether;

    constructor() {
        token = new MockToken();
        queue = new StakingReleaseQueue(token);
    }

    function run() external {
        // Scenario from the finding:
        // After prior processing: startIdx = 100, length = 15 pending releases
        // at absolute indices 100..114, all claimable (releaseAt <= block.number).
        queue.setState(100, 15);
        for (uint16 i = 100; i < 115; i++) {
            queue.writeRelease(i, 0, 1 ether); // releaseAt 0 → immediately claimable
        }

        require(queue.startIdx() == 100, "start");
        require(queue.pendingLength() == 15, "len");
        require(queue.releaseAmount(100) == 1 ether, "slot");

        // claim → compact: while (i < length) => while (100 < 15) never enters
        uint256 paid = queue.claim(address(this));

        // Harm: 15 ether of claimable collateral permanently unprocessed
        require(paid == 0, "must pay nothing due to bug");
        require(token.balanceOf(address(this)) == 0, "no tokens");
        require(queue.pendingLength() == 15, "still pending");
        require(queue.startIdx() == 100, "startIdx stuck");
        // Absolute slots still hold the funds
        require(queue.releaseAmount(100) == 1 ether, "still locked at 100");
        require(queue.releaseAmount(114) == 1 ether, "still locked at 114");
    }
}
