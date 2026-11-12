// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Harmonix FundContract — partial withdrawal clears isAcquired (Shieldify H-01, finding 57886)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    _updateUserWithdrawal sets isAcquired = false after every completion, including a
    partial one. The remaining 600 of an acquired 1000 then fails _canCompleteWithdraw
    and pays 0. The corrected update leaves the flag set until shares hit zero, pays
    the remaining 600, and a further withdraw pays 0.
    The blamed assignment is preserved verbatim (@> VULN). run() does not warp. */

contract MockToken {
    string public name = "Fund Asset";
    string public symbol = "ASSET";
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

contract FundContract {
    struct WithdrawData {
        uint256 withdrawAmount;
        uint256 shares;
        bool isAcquired;
    }

    MockToken public token;
    mapping(address => WithdrawData) public withdrawals;

    constructor(address token_) {
        token = MockToken(token_);
    }

    function seed(address user, uint256 shares, uint256 amount) external {
        withdrawals[user] = WithdrawData({withdrawAmount: amount, shares: shares, isAcquired: true});
    }

    function _canCompleteWithdraw(address user) private view returns (bool) {
        WithdrawData memory userWithdraw = withdrawals[user];
        return userWithdraw.isAcquired;
    }

    function withdraw(uint256 sharesOut) external returns (uint256 paid) {
        require(_canCompleteWithdraw(msg.sender), "not acquired");
        WithdrawData memory userWithdraw = withdrawals[msg.sender];
        uint256 withdrawAmount = (userWithdraw.withdrawAmount * sharesOut) / userWithdraw.shares;
        _updateUserWithdrawal(msg.sender, userWithdraw, sharesOut, withdrawAmount);
        token.transfer(msg.sender, withdrawAmount);
        return withdrawAmount;
    }

    // fundContract.sol _updateUserWithdrawal, store write reduced to the mapping.
    function _updateUserWithdrawal(
        address user,
        WithdrawData memory userWithdraw,
        uint256 _shares,
        uint256 withdrawAmount
    ) internal {
        userWithdraw.withdrawAmount -= withdrawAmount;
        userWithdraw.shares -= _shares;
        userWithdraw.isAcquired = false;
        withdrawals[user].withdrawAmount = userWithdraw.withdrawAmount;
        withdrawals[user].shares = userWithdraw.shares;
        // @> VULN: a partial withdrawal clears isAcquired even though shares remain
        withdrawals[user].isAcquired = false;
        // FIX: set isAcquired false only when userWithdraw.shares == 0
    }
}

contract FundFixed {
    struct WithdrawData {
        uint256 withdrawAmount;
        uint256 shares;
        bool isAcquired;
    }

    MockToken public token;
    mapping(address => WithdrawData) public withdrawals;

    constructor(address token_) {
        token = MockToken(token_);
    }

    function seed(address user, uint256 shares, uint256 amount) external {
        withdrawals[user] = WithdrawData({withdrawAmount: amount, shares: shares, isAcquired: true});
    }

    function withdraw(uint256 sharesOut) external returns (uint256 paid) {
        WithdrawData memory userWithdraw = withdrawals[msg.sender];
        if (userWithdraw.shares == 0 || !userWithdraw.isAcquired) return 0;
        uint256 withdrawAmount = (userWithdraw.withdrawAmount * sharesOut) / userWithdraw.shares;
        userWithdraw.withdrawAmount -= withdrawAmount;
        userWithdraw.shares -= sharesOut;
        if (userWithdraw.shares == 0) userWithdraw.isAcquired = false;
        withdrawals[msg.sender] = userWithdraw;
        token.transfer(msg.sender, withdrawAmount);
        return withdrawAmount;
    }
}

contract Depositor {
    function pull(FundContract fund, uint256 sharesOut) external returns (uint256 paid) {
        paid = fund.withdraw(sharesOut);
    }

    function pullFixed(FundFixed fund, uint256 sharesOut) external returns (uint256 paid) {
        paid = fund.withdraw(sharesOut);
    }
}

contract Exploit {
    uint256 public constant POSITION = 1000 ether;
    uint256 public constant PARTIAL = 400 ether;
    uint256 public constant REST = 600 ether;

    MockToken public token;
    FundContract public fund;
    Depositor public user;
    uint256 public firstPaid;
    uint256 public secondPaid;
    uint256 public shortfall;
    bool public stillAcquired;
    uint256 public sharesLeft;

    constructor() {
        token = new MockToken();
        fund = new FundContract(address(token));
        user = new Depositor();
    }

    function run() external {
        token.mint(address(fund), POSITION);
        fund.seed(address(user), POSITION, POSITION);
        firstPaid = user.pull(fund, PARTIAL);
        (uint256 sharesNow, uint256 amountNow, bool acquiredNow) = fund.withdrawals(address(user));
        sharesLeft = sharesNow;
        stillAcquired = acquiredNow;
        amountNow;
        try user.pull(fund, REST) returns (uint256 paid) {
            secondPaid = paid;
        } catch {
            secondPaid = 0;
        }
        shortfall = REST - secondPaid;
        require(firstPaid == PARTIAL, "first partial was not 400");
        require(sharesLeft == REST, "remaining shares are not 600");
        require(stillAcquired == false, "isAcquired was not cleared");
        require(secondPaid == 0, "second withdraw paid the remainder");
        require(shortfall == REST, "user is not short 600");
        require(token.balanceOf(address(user)) == PARTIAL, "user balance");
        require(token.balanceOf(address(fund)) == REST, "600 did not stay in the fund");
    }
}
