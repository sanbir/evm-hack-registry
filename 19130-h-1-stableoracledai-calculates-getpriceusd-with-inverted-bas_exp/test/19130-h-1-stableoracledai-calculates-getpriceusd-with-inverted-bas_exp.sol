// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    MiniToken,
    PriceFeeds,
    StableOracleDAIFixed,
    USSDMinter
} from "./19130-h-1-stableoracledai-calculates-getpriceusd-with-inverted-bas.sol";

contract Finding19130Test is Test {
    function test_inverted_base_mints_799_instead_of_1_ussd() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.price(), 799680127948820, "DAI/USD is not 1e18");
        assertEq(e.minted(), 799, "1 DAI mints 799 units");
        assertEq(e.ussd().balanceOf(address(e)), 799, "balance");
        assertEq(e.dai().balanceOf(address(e.minter())), 1e18, "minter kept the DAI");
        assertLt(e.minted() * 1000, 1_000_000, "below a thousandth of 1 USSD");
    }

    function test_control_inverts_chainlink_and_mints_one_ussd() public {
        PriceFeeds feeds = new PriceFeeds();
        StableOracleDAIFixed oracle = new StableOracleDAIFixed(address(feeds));
        MiniToken dai = new MiniToken("Dai", "DAI", 18);
        MiniToken ussd = new MiniToken("USSD", "USSD", 6);
        USSDMinter minter = new USSDMinter(address(dai), address(ussd), address(oracle));
        assertEq(oracle.getPriceUSD(), 1e18, "fair DAI price is $1");
        dai.mint(address(this), 1e18);
        dai.approve(address(minter), 1e18);
        uint256 minted = minter.mintForToken(1e18);
        assertEq(minted, 1_000_000, "1.000000 USSD");
        assertEq(ussd.balanceOf(address(this)), 1_000_000, "fair balance");
    }
}
