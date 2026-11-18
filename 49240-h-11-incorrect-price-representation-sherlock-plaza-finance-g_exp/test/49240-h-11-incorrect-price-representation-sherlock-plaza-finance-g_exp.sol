// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./49240-h-11-incorrect-price-representation-sherlock-plaza-finance-g.sol";

contract Finding49240Test is Test {
    function test_priceX96_is_lent_as_an_18_decimal_price() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.quote().balanceOf(address(e)), 24408239790603697707, "borrowed the raw scale");
        assertEq(e.quote().balanceOf(address(e.vault())), 0, "vault drained");
        (, int256 answer,,,) = e.oracle().latestRoundData();
        assertEq(uint256(answer), 24408239790603697707980053009065971527, "priceX96");
        assertEq(e.oracle().fairPrice18(uint256(answer)), 3245959692053023671448, "fair 18 dec");
    }
}
