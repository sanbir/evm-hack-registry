// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {SettlementBranch, Exploit} from "./37984-incorrect-logic-for-checking-isfillpricevalid-codehawks-zaro.sol";

contract IsFillPriceValidTest is Test {
    /// @notice CONTROL — a BUY order whose target/fill relationship
    ///         satisfies the (broken) deployed condition does fill,
    ///         illustrating that the branch is reachable and simply
    ///         inverted, not dead code.
    function test_buyOrder_fillsUnderBrokenCondition_wrongDirection() public {
        SettlementBranch branch = new SettlementBranch();
        // Broken condition for buy: target <= fill. Use target=90, fill=100.
        uint256 orderId = branch.createOffchainOrder(int128(1e18), 90e18);
        uint256[] memory ids = new uint256[](1);
        ids[0] = orderId;
        branch.fillOffchainOrders(ids, 100e18);
        (, , bool filled) = branch.orders(orderId);
        assertTrue(filled); // fills, but only because the check is backwards
    }

    /// @notice HARM — a take-profit SELL order set at a sensible target is
    ///         wrongly skipped even though the market clears the target,
    ///         and the trader's paper profit is wiped out when price
    ///         reverses because the order could never execute.
    function test_takeProfitOrder_neverFills_traderLosesLockedInProfit() public {
        Exploit exploit = new Exploit();
        exploit.run();
    }
}
