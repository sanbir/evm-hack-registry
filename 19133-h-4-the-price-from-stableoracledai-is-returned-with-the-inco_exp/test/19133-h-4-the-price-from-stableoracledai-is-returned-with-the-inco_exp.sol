// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    PriceFeeds,
    IDAIEthOracle,
    IEthUsdOracle,
    IDAIETHFeed
} from "./19133-h-4-the-price-from-stableoracledai-is-returned-with-the-inco.sol";

contract StableOracleDAIFixed {
    IDAIEthOracle public DAIEthOracle;
    IEthUsdOracle public ethOracle;
    IDAIETHFeed public priceFeedDAIETH;

    constructor(address feeds) {
        DAIEthOracle = IDAIEthOracle(feeds);
        ethOracle = IEthUsdOracle(feeds);
        priceFeedDAIETH = IDAIETHFeed(feeds);
    }

    function getPriceUSD() external view returns (uint256) {
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
        return (wethPriceUSD * 1e18) / ((DAIWethPrice + uint256(price)) / 2);
    }
}

contract Finding19133Test is Test {
    function test_exploit_overmints_ussd() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.ussd().balanceOf(address(e)), e.BUGGY_MINT(), "buggy mint");
        assertGt(e.ussd().balanceOf(address(e)), 1e18 * 1e9, "orders of magnitude over fair 1 USSD");
    }

    function test_control_fixed_oracle_prices_dai_at_one_dollar() public {
        PriceFeeds feeds = new PriceFeeds();
        StableOracleDAIFixed fixedOracle = new StableOracleDAIFixed(address(feeds));
        assertEq(fixedOracle.getPriceUSD(), 1e18, "fair DAI/USD is 1e18");
        Exploit e = new Exploit();
        uint256 buggy = e.oracle().getPriceUSD();
        assertEq(buggy, 199999999, "buggy price");
        assertLt(buggy, 1e9, "buggy price is ~1e10 too small");
    }
}
