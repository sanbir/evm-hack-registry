// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, BaseMilestoneFixed, MockToken} from "./47911-inaccurate-withdrawable-token-amount-ottersec-none-vtvl-pdf.sol";

contract InaccurateWithdrawableTest is Test {
    uint256 internal constant BALANCE = 1000 ether;
    uint256 internal constant RESERVED = 400 ether;
    uint256 internal constant WITHDRAWN = 200 ether;
    uint256 internal constant FAIR = 600 ether;

    function test_exploit_ownerWithdrawsLessThanFair() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.withdrawn(), WITHDRAWN, "withdrawn");
        assertEq(e.fair(), FAIR, "fair");
        assertEq(e.leftBehind(), FAIR - WITHDRAWN, "locked surplus");
        assertEq(e.token().balanceOf(address(e)), WITHDRAWN, "owner received the short amount");
        assertEq(e.token().balanceOf(address(e.milestone())), BALANCE - WITHDRAWN, "contract residual");
    }

    function test_control_balanceMinusReservedPaysTheFairAmount() public {
        MockToken token = new MockToken();
        BaseMilestoneFixed fixedMilestone = new BaseMilestoneFixed(address(token));
        token.mint(address(fixedMilestone), BALANCE);

        uint256 paid = fixedMilestone.withdrawAdmin();

        assertEq(paid, FAIR, "control did not pay the fair amount");
        assertEq(token.balanceOf(address(this)), FAIR, "owner did not receive 600");
        assertEq(token.balanceOf(address(fixedMilestone)), RESERVED, "reserved tokens were not left in place");
    }
}
