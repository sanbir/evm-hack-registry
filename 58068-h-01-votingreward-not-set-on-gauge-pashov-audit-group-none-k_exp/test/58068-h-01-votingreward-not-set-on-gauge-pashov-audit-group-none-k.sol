// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  KittenSwap Gauge — votingReward is never set (Pashov H-01, finding 58068)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    notifyRewardAmount approves votingReward and calls it. The address is unset,
    so the call reverts. A depositor claim pays 0 while 1000 of pair fees sit in
    the gauge. The control sets votingReward and that call pays the 1000.
    The blamed call is preserved (@> VULN). run() does not warp. */

contract MockToken {
    string public name = "Pair Fee";
    string public symbol = "FEE";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        require(allowance[from][msg.sender] >= amount, "allow");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

interface IVotingReward {
    function notifyRewardAmount(address token, uint256 amount) external;
}

contract Gauge {
    MockToken public token;
    IVotingReward public votingReward;
    uint256 public held;
    uint256 public notified;

    constructor(address token_) {
        token = MockToken(token_);
    }

    function pullFees(uint256 amount) external {
        token.mint(address(this), amount);
        held = amount;
    }

    // Quoted Gauge.notifyRewardAmount. votingReward was never assigned.
    function forwardFees() external {
        uint256 claimed0 = held;
        if (claimed0 > 0) {
            token.approve(address(votingReward), claimed0);
            // @> VULN: votingReward is unset, so the fee notification reverts and nothing is paid
            votingReward.notifyRewardAmount(address(token), claimed0);
            notified = claimed0;
        }
    }

    function claim(address user) external returns (uint256 paid) {
        paid = notified;
        if (paid > 0) {
            token.transfer(user, paid);
            notified = 0;
        }
    }
}

contract Reward {
    address public depositor;

    constructor(address depositor_) {
        depositor = depositor_;
    }

    function notifyRewardAmount(address token, uint256 amount) external {
        MockToken(token).transferFrom(msg.sender, depositor, amount);
    }
}

contract GaugeFixed {
    MockToken public token;
    IVotingReward public votingReward;
    uint256 public held;

    constructor(address token_, address reward_) {
        token = MockToken(token_);
        votingReward = IVotingReward(reward_);
    }

    function pullFees(uint256 amount) external {
        token.mint(address(this), amount);
        held = amount;
    }

    function forwardFees() external {
        token.approve(address(votingReward), held);
        votingReward.notifyRewardAmount(address(token), held);
        held = 0;
    }
}

contract Exploit {
    uint256 public constant FEES = 1000 ether;

    MockToken public token;
    Gauge public gauge;
    bool public forwarded;
    uint256 public claimed;
    uint256 public stuck;

    constructor() {
        token = new MockToken();
        gauge = new Gauge(address(token));
    }

    function run() external {
        gauge.pullFees(FEES);
        try gauge.forwardFees() {
            forwarded = true;
        } catch {
            forwarded = false;
        }
        claimed = gauge.claim(address(this));
        stuck = token.balanceOf(address(gauge));
        require(address(gauge.votingReward()) == address(0), "reward was set");
        require(forwarded == false, "notify succeeded");
        require(claimed == 0, "claim paid something");
        require(stuck == FEES, "fees did not stay in the gauge");
    }
}
