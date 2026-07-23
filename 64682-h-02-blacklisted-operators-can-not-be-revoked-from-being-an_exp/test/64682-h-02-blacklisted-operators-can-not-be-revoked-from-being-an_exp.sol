// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./64682-h-02-blacklisted-operators-can-not-be-revoked-from-being-an.sol";

contract ShinyBlacklistRevokeTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.rwa().balanceOf(address(e.attacker())), e.N(), "attacker stole NFTs");
        assertEq(e.rwa().balanceOf(address(e.victim())), 0, "victim emptied");
        // operator still set — victim could not revoke
        assertTrue(e.rwa().isApprovedForAll(address(e.victim()), address(e.router())), "op stuck");
    }

    function test_revokeAllowedWhenNotBlacklisted() public {
        AdminHelper adminH = new AdminHelper();
        sRWA rwa = new sRWA(address(adminH));
        address user = makeAddr("user");
        address op = makeAddr("op");
        adminH.mintMany(rwa, user, 1);

        vm.prank(user);
        rwa.setApprovalForAll(op, true);
        assertTrue(rwa.isApprovedForAll(user, op));

        vm.prank(user);
        rwa.setApprovalForAll(op, false); // works when not blacklisted
        assertFalse(rwa.isApprovedForAll(user, op));
    }
}
