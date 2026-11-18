// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Regnum Aurum DebtToken — H-12 (Pashov, 2025-05-06), finding 66353.
    burn() computes amount - scaledBalanceIncrease before the branch that
    should accept a payment smaller than accrued interest. A 50 token
    repayment reverts. The borrower can clear the 100 interest only by
    paying all of it. */

contract Token {
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s) {
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
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
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract DebtToken {
    Token public asset;
    uint256 public scaledBalance = 1000 ether;
    uint256 public scaledBalanceIncrease = 100 ether;
    uint256 public burnedPrincipal;

    constructor(Token _asset) {
        asset = _asset;
    }

    function burn(uint256 amount) external {
        require(asset.transferFrom(msg.sender, address(this), amount), "pay");
        // @> VULN: amount - accrued interest underflows when the payment is partial
        uint256 amountAfterPaidInterest = amount - scaledBalanceIncrease;
        if (amountAfterPaidInterest > 0) {
            scaledBalanceIncrease = 0;
            scaledBalance -= amountAfterPaidInterest;
            burnedPrincipal += amountAfterPaidInterest;
        } else {
            scaledBalanceIncrease = scaledBalanceIncrease - amount;
        }
    }
}

contract DebtTokenFixed {
    Token public asset;
    uint256 public scaledBalance = 1000 ether;
    uint256 public scaledBalanceIncrease = 100 ether;

    constructor(Token _asset) {
        asset = _asset;
    }

    function burn(uint256 amount) external {
        require(asset.transferFrom(msg.sender, address(this), amount), "pay");
        if (amount > scaledBalanceIncrease) {
            uint256 principal = amount - scaledBalanceIncrease;
            scaledBalanceIncrease = 0;
            scaledBalance -= principal;
        } else {
            scaledBalanceIncrease = scaledBalanceIncrease - amount;
        }
    }
}

contract Exploit {
    Token public asset;
    DebtToken public debt;
    bool public partialAccepted;
    uint256 public interestAfterPartial;
    uint256 public interestAfterFull;
    uint256 public paid;

    constructor() {
        asset = new Token("debt");
        debt = new DebtToken(asset);
        asset.mint(address(this), 100 ether);
    }

    function _tryBurn(uint256 amount) internal returns (bool ok) {
        try debt.burn(amount) {
            ok = true;
        } catch {
            ok = false;
        }
    }

    function run() external {
        asset.approve(address(debt), 100 ether);
        partialAccepted = _tryBurn(50 ether);
        interestAfterPartial = debt.scaledBalanceIncrease();
        debt.burn(100 ether);
        interestAfterFull = debt.scaledBalanceIncrease();
        paid = asset.balanceOf(address(debt));
        require(partialAccepted == false, "50 payment must revert");
        require(interestAfterPartial == 100 ether, "interest stays 100");
        require(interestAfterFull == 0, "only the full 100 clears interest");
        require(paid == 100 ether, "borrower paid the full interest");
        require(debt.scaledBalance() == 1000 ether, "principal unchanged");
        require(debt.burnedPrincipal() == 0, "no principal burned");
    }
}
