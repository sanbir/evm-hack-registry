// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, CasimirManager} from "./35004-incorrect-accounting-of-reportrecoveredeffectivebalance-can.sol";
contract Finding35004Test is Test {
    function test_report_finalization_underflows() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.bricked());
        assertFalse(e.manager().finalized());
    }
    function test_control_recovered_balance_finalizes() public {
        CasimirManager m = new CasimirManager();
        m.loadPeriod2();
        uint256 bal = m.finalizeReportFixed();
        assertEq(bal, 0);
        assertTrue(m.finalized());
    }
}
