// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    CollateralToken,
    Exploit,
    Market,
    Math,
    PythOracleFixed,
    Trader
} from "./24299-h-1-oracle-request-timestamp-and-pending-position-timestamp.sol";

contract Finding24299Test is Test {
    function test_exploit_close_ignored_collateral_locked() public {
        Exploit e = new Exploit();
        e.run();

        Market market = e.market();
        Trader trader = e.trader();
        CollateralToken token = e.token();

        assertEq(market.positionLong(address(trader)), market.POSITION_SIZE(), "long still 1.000000");
        assertEq(market.POSITION_SIZE(), 1_000_000, "stated size");
        assertTrue(market.closeIgnored(), "close ignored");
        assertEq(token.balanceOf(address(market)), 1_000 ether, "1000 collateral locked");
        assertEq(token.balanceOf(address(trader)), 0, "trader did not get collateral back");

        uint256 requested = e.oracle().versionList(0);
        uint256 positionTs = market.pendingTimestamp(address(trader));
        assertEq(requested, block.timestamp, "request stamped block.timestamp");
        assertEq(positionTs, Math.ceilDiv(block.timestamp, 100) * 100, "position stamped current()");
        assertTrue(requested != positionTs, "mismatch");
    }

    function test_control_matching_timestamp_accepts_close() public {
        CollateralToken token = new CollateralToken();
        PythOracleFixed oracle = new PythOracleFixed();
        Market market = new Market(token, oracle);
        Trader trader = new Trader(token, market);

        token.mint(address(trader), market.COLLATERAL());
        trader.open();
        oracle.commitRequested(100e6);
        trader.close();
        market.settleClose(address(trader));

        assertFalse(market.closeIgnored(), "control applied the close");
        assertEq(market.positionLong(address(trader)), 0, "long closed");
        assertEq(token.balanceOf(address(market)), 0, "market released collateral");
        assertEq(token.balanceOf(address(trader)), 1_000 ether, "trader received 1000 collateral");
        assertEq(oracle.versionList(0), oracle.current(), "request key is current()");
    }
}
