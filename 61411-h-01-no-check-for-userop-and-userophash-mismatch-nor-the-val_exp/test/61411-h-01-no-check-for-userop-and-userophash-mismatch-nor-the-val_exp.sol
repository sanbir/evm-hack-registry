// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./61411-h-01-no-check-for-userop-and-userophash-mismatch-nor-the-val.sol";

contract Etherspot61411Test is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.sessionClaimedByAttacker(), "session claimed");
        assertTrue(e.victimExecuteReverted(), "victim bricked");
        assertEq(e.lockedAfterAttack(), 1000, "tokens still locked");
    }

    /// @notice Control: when called by the real SCW (sender match), session claims cleanly
    ///         and locked tokens can be released via the legitimate path.
    function test_legitimateClaim_byAccount() public {
        CredibleAccountModule module = new CredibleAccountModule();
        ModularAccount scw = new ModularAccount(module);
        address sessionKey = address(0x5E55);
        scw.installAndEnable(sessionKey, 1000);

        // Legitimate execute by the account itself
        bool ok = scw.executeUserOp(sessionKey);
        assertTrue(ok, "legit execute");
        assertTrue(module.isSessionClaimed(sessionKey), "claimed");
        assertEq(module.lockedTokens(address(scw)), 0, "tokens released");
    }
}
