// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, FundFixed, MockToken} from "./57888-h-03-partial-withdrawers-suffer-double-fee-charging-due-to-s.sol";

contract DoubleFeeTest is Test {
    address internal constant FEE = 0x0000000000000000000000000000000000000B0b;

    function test_exploit_secondPartialChargesTheFullFeeAgain() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.firstFee(), 50 ether, "first");
        assertEq(e.feeLeftInStorage(), 100 ether, "fee not reduced");
        assertEq(e.secondFee(), 100 ether, "second");
        assertEq(e.totalFee(), 150 ether, "total");
        assertEq(e.extra(), 50 ether, "extra");
        assertEq(e.token().balanceOf(FEE), 150 ether, "receiver");
    }

    function test_control_reducesTheStoredFeeAndCharges100Once() public {
        MockToken token = new MockToken();
        FundFixed fund = new FundFixed(address(token), FEE);
        token.mint(address(fund), 1000 ether);
        fund.seed(address(this), 1000, 1000 ether, 100 ether);

        uint256 first = fund.redeem(500);
        uint256 second = fund.redeem(500);

        assertEq(first, 50 ether, "control first");
        assertEq(second, 50 ether, "control second charges the remainder once");
        assertEq(first + second, 100 ether, "charged once in total");
        assertEq(token.balanceOf(FEE), 100 ether, "receiver got 100");
    }
}
