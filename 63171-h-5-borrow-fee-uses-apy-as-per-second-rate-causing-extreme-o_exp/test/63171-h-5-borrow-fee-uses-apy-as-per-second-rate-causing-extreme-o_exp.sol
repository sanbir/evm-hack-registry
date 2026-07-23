// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./63171-h-5-borrow-fee-uses-apy-as-per-second-rate-causing-extreme-o.sol";

contract AmmplifyBorrowFeeApyTest is Test {
    function test_exploit_apyUsedAsPerSecondOvercharges() public {
        Exploit e = new Exploit();
        e.run();
        assertGt(e.feePaid(), e.correctFee(), "overcharge");
        assertGt(e.feePaid(), 5e18, "material fee");
    }
}
