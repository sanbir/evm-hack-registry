// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Harmonix FundContract — partial redeem charges the full fee twice (Shieldify H-03, finding 57888)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    _updateUserWithdrawal reduces shares and withdrawAmount but leaves managementFee
    at the original 100. The second half therefore charges 100 instead of 50.
    Two partials take 150. The fair total is 100. The extra fee is 50.
    The blamed fee product is preserved (@> VULN). run() does not warp. */

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
        uint256 managementFee;
    }

    MockToken public token;
    address public feeReceiver;
    mapping(address => WithdrawData) public withdrawals;
    uint256 public lastFee;
    uint256 public firstFeeCharged;
    uint256 public secondFeeCharged;
    uint256 public redeemCount;
    uint256 public storedFeeAfterFirst;

    constructor(address token_, address feeTo) {
        token = MockToken(token_);
        feeReceiver = feeTo;
    }

    function seed(address user, uint256 shares, uint256 amount, uint256 fee) external {
        withdrawals[user] = WithdrawData({withdrawAmount: amount, shares: shares, managementFee: fee});
    }

    function redeem(uint256 sharesOut) external returns (uint256 fee) {
        WithdrawData memory userWithdraw = withdrawals[msg.sender];
        uint256 gross = (userWithdraw.withdrawAmount * sharesOut) / userWithdraw.shares;
        // @> VULN: managementFee is still the original full fee, so the next partial charges it again
        lastFee = (sharesOut * userWithdraw.managementFee) / userWithdraw.shares;
        fee = lastFee;
        _updateUserWithdrawal(msg.sender, userWithdraw, sharesOut, gross);
        if (redeemCount == 0) {
            firstFeeCharged = fee;
            storedFeeAfterFirst = withdrawals[msg.sender].managementFee;
        } else {
            secondFeeCharged = fee;
        }
        redeemCount += 1;
        token.transfer(feeReceiver, fee);
        token.transfer(msg.sender, gross - fee);
    }

    // Quoted _updateUserWithdrawal. managementFee is not reduced.
    function _updateUserWithdrawal(
        address user,
        WithdrawData memory userWithdraw,
        uint256 _shares,
        uint256 withdrawAmount
    ) internal {
        userWithdraw.withdrawAmount -= withdrawAmount;
        userWithdraw.shares -= _shares;
        withdrawals[user].withdrawAmount = userWithdraw.withdrawAmount;
        withdrawals[user].shares = userWithdraw.shares;
        withdrawals[user].managementFee = userWithdraw.managementFee;
    }
}

contract FundFixed {
    struct WithdrawData {
        uint256 withdrawAmount;
        uint256 shares;
        uint256 managementFee;
    }

    MockToken public token;
    address public feeReceiver;
    mapping(address => WithdrawData) public withdrawals;

    constructor(address token_, address feeTo) {
        token = MockToken(token_);
        feeReceiver = feeTo;
    }

    function seed(address user, uint256 shares, uint256 amount, uint256 fee) external {
        withdrawals[user] = WithdrawData({withdrawAmount: amount, shares: shares, managementFee: fee});
    }

    function redeem(uint256 sharesOut) external returns (uint256 fee) {
        WithdrawData memory userWithdraw = withdrawals[msg.sender];
        uint256 gross = (userWithdraw.withdrawAmount * sharesOut) / userWithdraw.shares;
        fee = (sharesOut * userWithdraw.managementFee) / userWithdraw.shares;
        userWithdraw.withdrawAmount -= gross;
        userWithdraw.shares -= sharesOut;
        userWithdraw.managementFee -= fee;
        withdrawals[msg.sender] = userWithdraw;
        token.transfer(feeReceiver, fee);
        token.transfer(msg.sender, gross - fee);
    }
}

contract Exploit {
    address public constant FEE = 0x0000000000000000000000000000000000000B0b;
    uint256 public constant FULL_FEE = 100 ether;
    uint256 public constant POSITION = 1000 ether;

    MockToken public token;
    FundContract public fund;
    uint256 public firstFee;
    uint256 public secondFee;
    uint256 public totalFee;
    uint256 public extra;
    uint256 public feeLeftInStorage;

    constructor() {
        token = new MockToken();
        fund = new FundContract(address(token), FEE);
    }

    function run() external {
        token.mint(address(fund), POSITION);
        fund.seed(address(this), 1000, POSITION, FULL_FEE);
        fund.redeem(500);
        firstFee = fund.firstFeeCharged();
        feeLeftInStorage = fund.storedFeeAfterFirst();
        fund.redeem(500);
        secondFee = fund.secondFeeCharged();
        totalFee = firstFee + secondFee;
        extra = totalFee - FULL_FEE;
        require(firstFee == 50 ether, "first fee is not 50");
        require(feeLeftInStorage == FULL_FEE, "stored fee was reduced");
        require(secondFee == 100 ether, "second fee is not 100");
        require(totalFee == 150 ether, "total fee is not 150");
        require(extra == 50 ether, "extra fee is not 50");
        require(token.balanceOf(FEE) == 150 ether, "fee receiver");
    }
}
