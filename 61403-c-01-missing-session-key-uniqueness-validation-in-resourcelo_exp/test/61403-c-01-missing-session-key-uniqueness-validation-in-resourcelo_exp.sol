// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    CredibleAccountModuleFixed,
    Exploit,
    Token
} from "./61403-c-01-missing-session-key-uniqueness-validation-in-resourcelo.sol";

contract Finding61403Test is Test {
    function test_exploit_second_key_spends_the_wallet() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.storedUntil(), e.SECOND_UNTIL(), "first validUntil was overwritten");
        assertEq(e.spent(), 1_000 ether, "attacker key spent N");
        assertEq(e.token().balanceOf(address(this)), 1_000 ether, "caller received the wallet funds");
        assertEq(e.token().balanceOf(address(e)), 0, "wallet is empty");
        assertEq(e.N(), 1_000 ether, "harm magnitude");
    }

    function test_control_rejects_the_duplicate() public {
        Token token = new Token();
        CredibleAccountModuleFixed module = new CredibleAccountModuleFixed();
        address sessionKey = address(0x3333333333333333333333333333333333333333);
        uint256 n = 1_000 ether;

        token.mint(address(this), n);
        token.approve(address(module), n);
        module.enableSessionKey(sessionKey, 1, 1_800_000_000, address(token), 100 ether);

        vm.expectRevert(
            abi.encodeWithSelector(CredibleAccountModuleFixed.SessionKeyAlreadyLive.selector, sessionKey)
        );
        module.enableSessionKey(sessionKey, 1, 1_900_000_000, address(token), n);

        vm.expectRevert(CredibleAccountModuleFixed.NoMatchingLock.selector);
        module.spend(sessionKey, address(this), address(token), address(this), n);

        assertEq(token.balanceOf(address(this)), n, "wallet kept its funds");
        assertEq(module.validUntilOf(sessionKey, address(this)), 1_800_000_000, "first window remains");
    }
}
