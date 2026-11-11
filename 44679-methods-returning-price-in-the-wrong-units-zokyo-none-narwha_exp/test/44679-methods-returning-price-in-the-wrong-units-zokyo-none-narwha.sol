// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Narwhal TradingVaultV2 — getPricePerFullShare changes units
    (Zokyo, 2023-06-09 Narwhal Finance, high).

    SYNTHETIC, cheatcode-free reduction. One 18-decimal share is backed
    by 1 USDT (1e6 raw). Supply zero would return 1e18. Supply above
    zero returns balance * 1e18 / supply = 1e6. borrow() treats that
    price as a 1e18 unit and pays shares * price / 1e18 = 1e6 credit.
    The fair 1e18 price pays 1e18. The control scales the 6-decimal
    price up by 10**(18-decimals) before the same division. */

contract MockCredit {
    string public name = "Credit";
    string public symbol = "CREDIT";
    uint8 public decimals = 18;
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

contract TradingVaultV2 {
    uint8 public constant USDT_DECIMALS = 6;
    MockCredit public credit;
    uint256 public totalSupply;
    uint256 public usdtBalance;

    constructor(address _credit) {
        credit = MockCredit(_credit);
    }

    function balance() public view returns (uint256) {
        return usdtBalance;
    }

    function seed(uint256 supply, uint256 usdt) external {
        totalSupply = supply;
        usdtBalance = usdt;
    }

    function getPricePerFullShare() public view returns (uint256) {
        if (totalSupply == 0) {
            return 1e18;
        }
        // @> VULN: non-zero supply returns a 6-decimal USDT unit, not the 1e18 unit
        return (balance() * 1e18) / totalSupply;
    }

    function borrow(uint256 shares) external virtual {
        uint256 price = getPricePerFullShare();
        uint256 creditOut = (shares * price) / 1e18;
        require(credit.transfer(msg.sender, creditOut), "credit");
    }
}

contract TradingVaultV2Fixed is TradingVaultV2 {
    constructor(address _credit) TradingVaultV2(_credit) {}

    function borrow(uint256 shares) external override {
        uint256 price = getPricePerFullShare();
        // FIX: lift the 6-decimal price into the 1e18 unit the zero-supply branch uses
        uint256 price18 = price * (10 ** (18 - USDT_DECIMALS));
        uint256 creditOut = (shares * price18) / 1e18;
        require(credit.transfer(msg.sender, creditOut), "credit");
    }
}

contract Exploit {
    uint256 public constant SHARES = 1e18;
    uint256 public constant ONE_USDT = 1e6;
    uint256 public constant WRONG_PRICE = 1e6;
    uint256 public constant FAIR_PRICE = 1e18;
    uint256 public constant PAID = 1e6;
    uint256 public constant FAIR_CREDIT = 1e18;
    uint256 public constant SHORTFALL = 999999999999000000;

    MockCredit public credit; // nonce 1
    TradingVaultV2 public vault; // nonce 2

    uint256 public price;
    uint256 public fairPrice;
    uint256 public paid;
    uint256 public unpaid;

    constructor() {
        credit = new MockCredit();
        vault = new TradingVaultV2(address(credit));
    }

    function run() external {
        vault.seed(SHARES, ONE_USDT);
        price = vault.getPricePerFullShare();
        require(price == WRONG_PRICE, "price");
        fairPrice = price * (10 ** (18 - vault.USDT_DECIMALS()));
        require(fairPrice == FAIR_PRICE, "fair price");
        credit.mint(address(vault), FAIR_CREDIT);
        vault.borrow(SHARES);
        paid = credit.balanceOf(address(this));
        unpaid = credit.balanceOf(address(vault));
        require(paid == PAID, "paid");
        require(unpaid == SHORTFALL, "unpaid");
        require(FAIR_CREDIT - paid == SHORTFALL, "gap");
    }
}
