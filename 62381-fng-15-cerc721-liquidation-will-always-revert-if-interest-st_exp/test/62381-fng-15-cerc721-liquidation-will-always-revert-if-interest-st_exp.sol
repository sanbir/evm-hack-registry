// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, CTokenFixed} from
    "./62381-fng-15-cerc721-liquidation-will-always-revert-if-interest-st.sol";

contract Finding62381Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_same_block_accrue_blocks_liquidation() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.market().collateral(), 100 ether, "collateral not seized");
        assertEq(e.market().lastSeized(), 0, "seize amount is 0");
        assertEq(e.marker().balanceOf(SINK), 100 ether, "100 unseized");
    }

    function test_control_short_circuit_returns_the_exchange_rate() public {
        CTokenFixed market = new CTokenFixed();
        uint256 first = market.accrueInterest();
        uint256 seized = market.liquidate();
        assertEq(first, 2 ether, "rate");
        assertEq(seized, 100 ether, "collateral seized");
        assertEq(market.collateral(), 0, "market paid the collateral");
    }
}
