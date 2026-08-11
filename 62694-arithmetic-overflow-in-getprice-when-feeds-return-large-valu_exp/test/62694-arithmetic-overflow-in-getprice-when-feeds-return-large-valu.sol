// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of NUTS Finance (Pike) finding 62694:
// "Arithmetic Overflow in getPrice When Feeds Return Large Values".
//
// ChainlinkOracleComposite.getPrice() normalises each Chainlink feed answer to a
// 36-decimal fixed-point rate and folds it into a running compositePrice with a
// PLAIN 256-bit multiply:
//
//     rate           = uint256(price) * 10**(SCALING_DECIMALS - feed.decimals());
//     compositePrice = (compositePrice * rate) / SCALING_FACTOR;   // 36-dec fp
//
// The intermediate `compositePrice * rate` is a raw uint256 product. When a feed
// reports a large-but-VALID price (> ~$100k), that product exceeds 2^256-1 and the
// call reverts with an arithmetic overflow (Panic 0x11). Because getPrice() is the
// pricing primitive for every dependent market, a single legitimate high price
// bricks the oracle and freezes all lending / liquidation / pricing that reads it.
//
// The verbatim vulnerable arithmetic is inlined below (marked `// @>`). The fixed
// variant applies the finding's own recommendation — OpenZeppelin's 512-bit
// Math.mulDiv — and returns a finite price for the identical input, proving the
// defect is the unguarded `*`/`/` pair, not the setup.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Real OpenZeppelin Math.mulDiv (512-bit intermediate; floor). Inlined
///      verbatim so the FIXED oracle can multiply the same operands without the
///      256-bit intermediate ever overflowing.
library Math {
    function mulDiv(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0 = x * y;
            uint256 prod1;
            assembly {
                let mm := mulmod(x, y, not(0))
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            if (prod1 == 0) {
                return prod0 / denominator;
            }
            require(denominator > prod1, "Math: mulDiv overflow");
            uint256 remainder;
            assembly {
                remainder := mulmod(x, y, denominator)
                prod0 := sub(prod0, remainder)
                prod1 := sub(prod1, gt(remainder, prod0))
            }
            uint256 twos = denominator & (0 - denominator);
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;
            uint256 inverse = (3 * denominator) ^ 2;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            result = prod0 * inverse;
            return result;
        }
    }
}

/// @dev Minimal ERC20 double used for locked collateral + the harm marker.
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

/// @dev Chainlink AggregatorV3 interface (subset the oracle reads).
interface IAggregator {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @dev Faithful minimal double for the OPAQUE external boundary — a Chainlink
///      price feed. Its answer is legitimately settable to any valid price; the
///      finding's harm triggers on ordinary large-but-valid answers.
contract MockAggregator is IAggregator {
    uint8 public immutable feedDecimals;
    int256 internal answer;

    constructor(uint8 _decimals, int256 _answer) {
        feedDecimals = _decimals;
        answer = _answer;
    }

    function setAnswer(int256 a) external {
        answer = a;
    }

    function decimals() external view returns (uint8) {
        return feedDecimals;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }
}

interface IPriceOracle {
    function getPrice() external view returns (uint256);
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — verbatim buggy arithmetic from the finding inlined.
// ─────────────────────────────────────────────────────────────────────────────
contract ChainlinkOracleComposite is IPriceOracle {
    uint256 internal constant SCALING_FACTOR = 1e36;
    uint256 internal constant SCALING_DECIMALS = 36;

    IAggregator[] public feeds;

    constructor(IAggregator[] memory _feeds) {
        for (uint256 i = 0; i < _feeds.length; i++) {
            feeds.push(_feeds[i]);
        }
    }

    /// @notice Composite price = product of every feed's normalised rate.
    function getPrice() external view returns (uint256) {
        uint256 compositePrice = SCALING_FACTOR;
        for (uint256 i = 0; i < feeds.length; i++) {
            IAggregator feed = feeds[i];
            (, int256 price,,,) = feed.latestRoundData();
            uint256 rate = uint256(price)
                * 10**(SCALING_DECIMALS - feed.decimals());
            compositePrice = (compositePrice * rate) // @> plain 256-bit multiply: `compositePrice * rate` overflows and reverts once a feed reports a large-but-valid price (> ~$100k), permanently bricking the oracle
                / SCALING_FACTOR; // 36-dec fixed-point
        }
        return compositePrice;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract — identical loop, but the fold uses OZ's 512-bit Math.mulDiv
// (the finding's recommendation), so the same large feed answer never overflows.
// ─────────────────────────────────────────────────────────────────────────────
contract ChainlinkOracleCompositeFixed is IPriceOracle {
    uint256 internal constant SCALING_FACTOR = 1e36;
    uint256 internal constant SCALING_DECIMALS = 36;

    IAggregator[] public feeds;

    constructor(IAggregator[] memory _feeds) {
        for (uint256 i = 0; i < _feeds.length; i++) {
            feeds.push(_feeds[i]);
        }
    }

    function getPrice() external view returns (uint256) {
        uint256 compositePrice = SCALING_FACTOR;
        for (uint256 i = 0; i < feeds.length; i++) {
            IAggregator feed = feeds[i];
            (, int256 price,,,) = feed.latestRoundData();
            uint256 rate = uint256(price) * 10**(SCALING_DECIMALS - feed.decimals());
            // FIX: 512-bit intermediate — no 256-bit overflow on large valid prices.
            compositePrice = Math.mulDiv(compositePrice, rate, SCALING_FACTOR);
        }
        return compositePrice;
    }
}

/// @dev Minimal dependent market: it must price collateral through the oracle to
///      liquidate or value a position. When the oracle bricks, both revert and the
///      deposited collateral is frozen — the concrete harm of the oracle DoS.
contract LendingMarket {
    IPriceOracle public oracle;
    MiniToken public collateral;
    uint256 public deposited;

    constructor(IPriceOracle _oracle, MiniToken _collateral) {
        oracle = _oracle;
        collateral = _collateral;
    }

    function deposit(uint256 amount) external {
        collateral.transferFrom(msg.sender, address(this), amount);
        deposited += amount;
    }

    /// @notice Value the deposited collateral — needs a live oracle price.
    function collateralValue() public view returns (uint256) {
        return oracle.getPrice() * deposited / 1e36;
    }

    /// @notice Liquidation is impossible without a price; reverts when oracle bricks.
    function liquidate() external view returns (uint256) {
        return collateralValue();
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: a legitimate high feed price ($1M) makes the buggy oracle's
// getPrice() overflow-revert, which freezes the dependent LendingMarket (it can no
// longer price or liquidate the deposited collateral). The frozen magnitude is
// recorded on a LOCKED marker to the SINK. Two negative controls prove causation:
//   * the FIXED oracle returns a finite price on the identical $1M feed;
//   * the SAME buggy oracle returns a finite price at a below-threshold ($50k) feed.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint8 internal constant FEED_DECIMALS = 8;
    int256 internal constant PRICE_1M = 1e14;   // $1,000,000 at 8 decimals — valid, over threshold
    int256 internal constant PRICE_50K = 5e12;  //   $50,000 at 8 decimals — valid, under threshold
    uint256 internal constant COLLATERAL = 1000 ether;

    // Exposed results for the driver.
    bool public buggyReverted;          // buggy getPrice() reverts on the $1M feed
    bool public marketFrozen;           // dependent market can no longer price/liquidate
    uint256 public fixedPrice;          // FIXED getPrice() on the same $1M feed (finite)
    uint256 public belowThresholdPrice; // buggy getPrice() on the $50k feed (finite)
    uint256 public lockedCollateral;    // collateral frozen in the bricked market
    uint256 public sinkMarkerBalance;

    address public oracleAddr;
    address public fixedAddr;
    address public feedAddr;
    address public marketAddr;
    address public markerAddr;

    function run() external payable {
        // --- deploy doubles + the real vulnerable oracle (marker LAST) ---
        MiniToken collateral = new MiniToken("Collateral", "COLL");        // nonce 1
        MockAggregator feed = new MockAggregator(FEED_DECIMALS, PRICE_1M);  // nonce 2

        IAggregator[] memory feedList = new IAggregator[](1);
        feedList[0] = IAggregator(address(feed));

        ChainlinkOracleComposite oracleBuggy = new ChainlinkOracleComposite(feedList); // nonce 3
        ChainlinkOracleCompositeFixed oracleFixed = new ChainlinkOracleCompositeFixed(feedList); // nonce 4
        LendingMarket market = new LendingMarket(IPriceOracle(address(oracleBuggy)), collateral); // nonce 5
        MiniToken marker = new MiniToken("Locked Collateral", "LOCKED-COLL"); // nonce 6 (LAST)

        oracleAddr = address(oracleBuggy);
        fixedAddr = address(oracleFixed);
        feedAddr = address(feed);
        marketAddr = address(market);
        markerAddr = address(marker);

        // --- a user deposits real collateral into the dependent market ---
        collateral.mint(address(this), COLLATERAL);
        collateral.approve(address(market), COLLATERAL);
        market.deposit(COLLATERAL);

        // --- HARM: at a valid $1M feed answer the buggy oracle overflow-reverts ---
        try oracleBuggy.getPrice() returns (uint256) {
            buggyReverted = false;
        } catch {
            buggyReverted = true;
        }

        // --- CONTROL 1: the FIXED oracle prices the identical $1M feed cleanly ---
        fixedPrice = oracleFixed.getPrice(); // must be finite (no revert)

        // --- CONTROL 2: the SAME buggy oracle works at a below-threshold $50k feed ---
        feed.setAnswer(PRICE_50K);
        belowThresholdPrice = oracleBuggy.getPrice(); // finite: proves it's the large value, not the setup

        // --- restore the bricking condition so the market stays frozen ---
        feed.setAnswer(PRICE_1M);

        // --- HARM: the dependent market can no longer price / liquidate ---
        try market.liquidate() returns (uint256) {
            marketFrozen = false;
        } catch {
            marketFrozen = true;
        }

        // --- record the frozen magnitude on the LOCKED marker at the SINK ---
        lockedCollateral = collateral.balanceOf(address(market));
        marker.mint(SINK, lockedCollateral);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
