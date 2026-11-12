// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  KittenSwap VotingEscrow — initial_last_point aliases last_point (Pashov H-05, finding 58016)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Point memory initial_last_point = last_point is a memory reference, not a copy.
    After last_point.ts = t_i, (t_i - initial_last_point.ts) is 0, so the historical
    block stays 800000 instead of advancing. A vote read at block 850000 therefore
    uses the decayed point and pays 604.8 ether instead of 1209.6 ether.
    The blamed block assignment is preserved (@> VULN). run() does not warp.
    The block height and timestamp are the single replay block. */

contract MockToken {
    string public name = "Vote Reward";
    string public symbol = "KITTEN";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract VotingEscrow {
    uint256 internal constant WEEK = 7 days;
    uint256 internal constant MULTIPLIER = 1e18;
    int128 internal constant SLOPE = int128(int256(1e15));
    uint256 internal constant INITIAL_BLK = 800_000;
    uint256 internal constant QUERY_BLK = 850_000;

    struct Point {
        int128 bias;
        int128 slope;
        uint256 ts;
        uint256 blk;
    }

    MockToken public token;
    Point[2] public pointHistory;
    uint256 public historicalBlk;
    uint256 public paidBias;
    uint256 public openedAt;

    constructor(address token_) {
        token = MockToken(token_);
    }

    function _checkpoint() internal {
        uint256 lastTs = block.timestamp - 2 * WEEK;
        openedAt = lastTs;
        Point memory last_point = Point({
            bias: SLOPE * int128(int256(2 * WEEK)),
            slope: SLOPE,
            ts: lastTs,
            blk: INITIAL_BLK
        });
        pointHistory[0] = last_point;

        uint256 block_slope = 0;
        if (block.timestamp > last_point.ts) {
            block_slope = (MULTIPLIER * (block.number - last_point.blk)) / (block.timestamp - last_point.ts);
        }

        Point memory initial_last_point = last_point;
        uint256 t_i = (lastTs / WEEK) * WEEK;
        uint256 last_checkpoint = lastTs;
        t_i += WEEK;
        last_point.bias -= last_point.slope * int128(int256(t_i - last_checkpoint));
        last_checkpoint = t_i;
        last_point.ts = t_i;
        // @> VULN: initial_last_point aliases last_point, so (t_i - initial_last_point.ts) is 0
        last_point.blk = initial_last_point.blk + (block_slope * (t_i - initial_last_point.ts)) / MULTIPLIER;
        // FIX: copy bias, slope, ts, and blk into a fresh Point
        historicalBlk = last_point.blk;
        pointHistory[1] = last_point;
    }

    function _votesAt(uint256 blk) internal view returns (uint256) {
        if (pointHistory[1].blk != 0 && pointHistory[1].blk <= blk) {
            return uint256(int256(pointHistory[1].bias));
        }
        return uint256(int256(pointHistory[0].bias));
    }

    function checkpointAndClaim(address user) external returns (uint256 paid) {
        _checkpoint();
        paid = _votesAt(QUERY_BLK);
        paidBias = paid;
        token.transfer(user, paid);
    }
}

contract VotingEscrowFixed {
    uint256 internal constant WEEK = 7 days;
    uint256 internal constant MULTIPLIER = 1e18;
    int128 internal constant SLOPE = int128(int256(1e15));
    uint256 internal constant INITIAL_BLK = 800_000;

    struct Point {
        int128 bias;
        int128 slope;
        uint256 ts;
        uint256 blk;
    }

    Point[2] public pointHistory;
    uint256 public historicalBlk;

    function checkpoint() external returns (uint256 blk, uint256 votes) {
        uint256 lastTs = block.timestamp - 2 * WEEK;
        Point memory last_point = Point({
            bias: SLOPE * int128(int256(2 * WEEK)),
            slope: SLOPE,
            ts: lastTs,
            blk: INITIAL_BLK
        });
        pointHistory[0] = last_point;
        uint256 block_slope = (MULTIPLIER * (block.number - last_point.blk)) / (block.timestamp - last_point.ts);
        Point memory initial_last_point = Point({
            bias: last_point.bias,
            slope: last_point.slope,
            ts: last_point.ts,
            blk: last_point.blk
        });
        uint256 t_i = lastTs + WEEK;
        last_point.bias -= last_point.slope * int128(int256(WEEK));
        last_point.ts = t_i;
        last_point.blk = initial_last_point.blk + (block_slope * (t_i - initial_last_point.ts)) / MULTIPLIER;
        historicalBlk = last_point.blk;
        pointHistory[1] = last_point;
        blk = historicalBlk;
        votes = uint256(int256(pointHistory[0].bias));
    }
}

contract Exploit {
    uint256 public constant INITIAL_BLK = 800_000;
    uint256 public constant LOW = 604_800_000_000_000_000_000;
    uint256 public constant HIGH = 1_209_600_000_000_000_000_000;

    MockToken public token;
    VotingEscrow public escrow;
    uint256 public historicalBlk;
    uint256 public paid;
    uint256 public shortfall;

    constructor() {
        token = new MockToken();
        escrow = new VotingEscrow(address(token));
    }

    function run() external {
        token.mint(address(escrow), LOW);
        paid = escrow.checkpointAndClaim(address(this));
        historicalBlk = escrow.historicalBlk();
        shortfall = HIGH - paid;
        require(historicalBlk == INITIAL_BLK, "historical block moved");
        require(paid == LOW, "paid the decayed point");
        require(shortfall == LOW, "not short one week of bias");
        require(token.balanceOf(address(this)) == LOW, "voter balance");
        require(block.number > INITIAL_BLK, "block did not advance past the old point");
    }
}
