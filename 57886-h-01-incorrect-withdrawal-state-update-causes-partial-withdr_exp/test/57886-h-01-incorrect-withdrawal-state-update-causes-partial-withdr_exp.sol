// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, FundFixed, MockToken, Depositor} from "./57886-h-01-incorrect-withdrawal-state-update-causes-partial-withdr.sol";

contract PartialWithdrawStateTest is Test {
    function test_exploit_partialLeavesUserShort600() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.firstPaid(), 400 ether, "first");
        assertEq(e.secondPaid(), 0, "second pays 0");
        assertEq(e.shortfall(), 600 ether, "short 600");
        assertEq(e.sharesLeft(), 600 ether, "shares remain");
        assertFalse(e.stillAcquired(), "flag cleared");
        assertEq(e.token().balanceOf(address(e.user())), 400 ether, "user holds 400");
        assertEq(e.token().balanceOf(address(e.fund())), 600 ether, "fund keeps 600");
    }

    function test_control_stateUpdatePaysRemainderThenZero() public {
        MockToken token = new MockToken();
        FundFixed fund = new FundFixed(address(token));
        Depositor user = new Depositor();
        token.mint(address(fund), 1000 ether);
        fund.seed(address(user), 1000 ether, 1000 ether);

        uint256 first = user.pullFixed(fund, 400 ether);
        uint256 second = user.pullFixed(fund, 600 ether);
        uint256 third = user.pullFixed(fund, 600 ether);

        assertEq(first, 400 ether, "control first");
        assertEq(second, 600 ether, "control pays the remainder");
        assertEq(third, 0, "further withdraw pays 0");
        assertEq(token.balanceOf(address(user)), 1000 ether, "user made whole");
        assertEq(token.balanceOf(address(fund)), 0, "nothing left locked");
    }
}
