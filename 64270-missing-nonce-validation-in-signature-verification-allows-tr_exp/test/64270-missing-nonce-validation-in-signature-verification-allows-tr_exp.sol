// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./64270-missing-nonce-validation-in-signature-verification-allows-tr.sol";

contract SecuritizeNonceReplayTest is Test {
    function test_replaysOneSignedSubscription() external {
        Exploit exploit = new Exploit();
        exploit.run();
        assertEq(exploit.dsToken().balanceOf(address(exploit)), 200, "duplicate issuance is the harm");
        assertEq(exploit.onRamp().noncePerInvestor(address(exploit)), 2, "nonce zero was accepted twice");
    }

    function test_freshTransactionsStillWork() external {
        Exploit exploit = new Exploit();
        exploit.run();
        assertEq(exploit.usdc().balanceOf(address(exploit)), 0);
    }
}
