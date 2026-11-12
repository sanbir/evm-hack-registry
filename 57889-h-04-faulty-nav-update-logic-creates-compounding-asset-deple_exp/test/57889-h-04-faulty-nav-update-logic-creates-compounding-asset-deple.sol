// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Harmonix FundContract — NAV subtracts the fee that is already inside the withdrawal
    (Shieldify H-04, finding 57889).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    withdrawAmount is the gross assets, and the management fee is computed from it
    without being removed. _updateVaultState then does nav -= withdrawAmount + fee.
    A 1000 withdrawal with a 100 fee drops NAV and assets by 1100. The fair drop is 1000.
    The vault is short 100. The blamed subtraction is preserved (@> VULN). run() does not warp. */

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
    MockToken public token;
    address public feeReceiver;
    uint256 public nav;
    uint256 public withdrawPoolAmount;
    uint256 public lastWithdrawAmount;
    uint256 public lastFee;
    uint256 public navDrop;

    constructor(address token_, address feeTo) {
        token = MockToken(token_);
        feeReceiver = feeTo;
    }

    function fundNav(uint256 amount) external {
        nav = amount;
        token.mint(address(this), amount);
    }

    // Quoted initiateWithdrawal: fee is calculated from withdrawAmount and not subtracted from it.
    function withdraw(uint256 shares) external returns (uint256 withdrawAmount) {
        withdrawAmount = shares;
        uint256 managementFee = withdrawAmount / 10;
        lastWithdrawAmount = withdrawAmount;
        lastFee = managementFee;
        _updateVaultState(withdrawAmount, managementFee);
        token.transfer(msg.sender, withdrawAmount);
        token.transfer(feeReceiver, managementFee);
    }

    // fundContract.sol _updateVaultState
    function _updateVaultState(uint256 withdrawAmount, uint256 feeAmount) internal {
        withdrawPoolAmount = withdrawAmount;
        // @> VULN: nav drops by withdrawAmount + feeAmount even though the fee is already inside withdrawAmount
        nav = nav - (withdrawAmount + feeAmount);
        // FIX: nav = nav - withdrawAmount
        navDrop = withdrawAmount + feeAmount;
    }
}

contract FundFixed {
    MockToken public token;
    address public feeReceiver;
    uint256 public nav;

    constructor(address token_, address feeTo) {
        token = MockToken(token_);
        feeReceiver = feeTo;
    }

    function fundNav(uint256 amount) external {
        nav = amount;
        token.mint(address(this), amount);
    }

    function withdraw(uint256 shares) external returns (uint256 withdrawAmount) {
        withdrawAmount = shares;
        uint256 managementFee = withdrawAmount / 10;
        managementFee;
        nav = nav - withdrawAmount;
        token.transfer(msg.sender, withdrawAmount);
    }
}

contract Exploit {
    address public constant FEE = 0x0000000000000000000000000000000000000B0b;
    uint256 public constant START_NAV = 10000 ether;
    uint256 public constant GROSS = 1000 ether;
    uint256 public constant FEE_AMT = 100 ether;

    MockToken public token;
    FundContract public fund;
    uint256 public navAfter;
    uint256 public assetsAfter;
    uint256 public dropped;
    uint256 public fairNav;
    uint256 public shortfall;
    uint256 public feePaid;

    constructor() {
        token = new MockToken();
        fund = new FundContract(address(token), FEE);
    }

    function run() external {
        fund.fundNav(START_NAV);
        fund.withdraw(GROSS);
        navAfter = fund.nav();
        assetsAfter = token.balanceOf(address(fund));
        dropped = fund.navDrop();
        fairNav = START_NAV - GROSS;
        shortfall = fairNav - navAfter;
        feePaid = token.balanceOf(FEE);
        require(fund.lastWithdrawAmount() == GROSS, "gross");
        require(fund.lastFee() == FEE_AMT, "fee inside the gross");
        require(dropped == GROSS + FEE_AMT, "drop is not 1100");
        require(navAfter == START_NAV - GROSS - FEE_AMT, "nav");
        require(assetsAfter == START_NAV - GROSS - FEE_AMT, "assets");
        require(shortfall == FEE_AMT, "vault is not short 100");
        require(feePaid == FEE_AMT, "extra fee left the vault");
    }
}
