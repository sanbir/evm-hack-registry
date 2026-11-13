// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  USSD StableOracleDAI — Chainlink DAI/ETH is averaged with a WETH/DAI quote
    (Sherlock 2023-05, H-1, finding 19130). Distinct from 19133's decimal scale.
    SYNTHETIC, cheatcode-free. The return expression is the audited line (@> VULN).

    Pool quote of 1 WETH is 2000 DAI (2000e18). Chainlink DAI/ETH is 0.0005e18.
    Those are reciprocals. The average is not a DAI-per-ETH price, so getPriceUSD
    is 799680127948820 instead of 1e18. mintForToken on 1 DAI mints 799 USSD
    units (6 decimals) instead of 1_000_000. */

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

/// Pool leg is DAI per 1 WETH. Chainlink leg is ETH per 1 DAI. ETH/USD is 2000e18.
contract PriceFeeds {
    function getPriceUSD() external pure returns (uint256) {
        return 2000 ether;
    }

    function quoteSpecificPoolsWithTimePeriod(
        uint256,
        address,
        address,
        address[] calldata,
        uint32
    ) external pure returns (uint256) {
        return 2000 ether;
    }

    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) {
        return (1, int256(0.0005 ether), 0, 0, 1);
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

    function getPriceUSD() public view virtual returns (uint256) {
        address[] memory pools = new address[](1);
        pools[0] = 0x60594a405d53811d3BC4766596EFD80fd545A270;
        uint256 DAIWethPrice = DAIEthOracle.quoteSpecificPoolsWithTimePeriod(
            1000000000000000000, // 1 Eth
            0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, // WETH (base token)
            0x6B175474E89094C44Da98b954EedeAC495271d0F, // DAI (quote token)
            pools,
            600
        );
        uint256 wethPriceUSD = ethOracle.getPriceUSD();
        (, int256 price,,,) = priceFeedDAIETH.latestRoundData();
        // @> VULN: `price` is DAI/ETH; DAIWethPrice is DAI per WETH. Averaging them is not a DAI price.
        return (wethPriceUSD * 1e18) / ((DAIWethPrice + uint256(price) * 1e10) / 2);
    }
}

contract StableOracleDAIFixed is StableOracleDAI {
    constructor(address feeds) StableOracleDAI(feeds) {}

    function getPriceUSD() public view override returns (uint256) {
        address[] memory pools = new address[](1);
        pools[0] = 0x60594a405d53811d3BC4766596EFD80fd545A270;
        uint256 DAIWethPrice = DAIEthOracle.quoteSpecificPoolsWithTimePeriod(
            1000000000000000000,
            0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
            0x6B175474E89094C44Da98b954EedeAC495271d0F,
            pools,
            600
        );
        uint256 wethPriceUSD = ethOracle.getPriceUSD();
        (, int256 price,,,) = priceFeedDAIETH.latestRoundData();
        uint256 ethPerDai = uint256(price);
        uint256 daiPerEth = 1e36 / ethPerDai;
        return (wethPriceUSD * 1e18) / ((DAIWethPrice + daiPerEth) / 2);
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

    /// Audited calculateMint: USSD has 6 decimals, DAI has 18.
    function mintForToken(uint256 tokenAmount) external returns (uint256 stableCoinAmount) {
        dai.transferFrom(msg.sender, address(this), tokenAmount);
        uint256 assetPrice = oracle.getPriceUSD();
        stableCoinAmount = ((assetPrice * tokenAmount) / 1e18) * 1e6 / 1e18;
        ussd.mint(msg.sender, stableCoinAmount);
    }
}

contract Exploit {
    uint256 public constant BUGGY_PRICE = 799680127948820;
    uint256 public constant FAIR_PRICE = 1e18;
    uint256 public constant BUGGY_MINT = 799;
    uint256 public constant FAIR_MINT = 1_000_000;
    uint256 public constant ONE_DAI = 1e18;

    PriceFeeds public feeds; // nonce 1
    StableOracleDAI public oracle; // nonce 2
    MiniToken public dai; // nonce 3
    MiniToken public ussd; // nonce 4
    USSDMinter public minter; // nonce 5

    uint256 public price;
    uint256 public minted;

    constructor() {
        feeds = new PriceFeeds();
        oracle = new StableOracleDAI(address(feeds));
        dai = new MiniToken("Dai", "DAI", 18);
        ussd = new MiniToken("USSD", "USSD", 6);
        minter = new USSDMinter(address(dai), address(ussd), address(oracle));
    }

    function run() external {
        price = oracle.getPriceUSD();
        dai.mint(address(this), ONE_DAI);
        dai.approve(address(minter), ONE_DAI);
        minted = minter.mintForToken(ONE_DAI);
        require(price == BUGGY_PRICE, "inverted price");
        require(minted == BUGGY_MINT, "799 units");
        require(ussd.balanceOf(address(this)) == BUGGY_MINT, "balance");
        require(dai.balanceOf(address(minter)) == ONE_DAI, "minter kept 1 DAI");
        require(minted * 1000 < FAIR_MINT, "far below 1 USSD");
    }
}
