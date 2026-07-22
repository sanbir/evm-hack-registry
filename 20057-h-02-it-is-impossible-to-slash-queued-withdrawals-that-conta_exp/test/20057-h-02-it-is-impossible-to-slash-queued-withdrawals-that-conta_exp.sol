// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./20057-h-02-it-is-impossible-to-slash-queued-withdrawals-that-conta.sol";

contract EigenLayerSlashSkipTest is Test {
    function test_slash_ignores_indicesToSkip_and_cannot_slash_malicious() public {
        Exploit exploit = new Exploit();

        // Sanity: before the attack the malicious strategy holds its full shares.
        assertEq(exploit.maliciousStrategy().totalShares(), exploit.MALICIOUS_AMT());

        exploit.run();

        // HARM 1 — indicesToSkip is completely ignored: the benign strategy the
        // owner tried to skip was withdrawn anyway (recipient received its full
        // balance despite skip = [0]).
        assertTrue(exploit.skipWasIgnored(), "indicesToSkip should have been ignored (bug)");
        assertEq(
            exploit.benignToken().balanceOf(exploit.RECIPIENT()),
            exploit.BENIGN_AMT(),
            "recipient should have received the SKIPPED strategy's funds"
        );

        // HARM 2 — a queued withdrawal containing a malicious strategy can NEVER
        // be slashed: naming it in indicesToSkip still reverts the whole slash,
        // and its shares are untouched (escape slashing / locked).
        assertTrue(exploit.maliciousSlashReverted(), "slash of malicious-strategy queue should revert");
        assertEq(
            exploit.maliciousStrategy().totalShares(),
            exploit.MALICIOUS_AMT(),
            "malicious strategy shares should be un-slashable (unchanged)"
        );
    }
}
