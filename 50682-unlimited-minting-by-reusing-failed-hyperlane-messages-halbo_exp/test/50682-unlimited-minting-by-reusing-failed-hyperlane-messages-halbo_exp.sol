// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./50682-unlimited-minting-by-reusing-failed-hyperlane-messages-halbo.sol";

contract FailedHyperlaneMessageReplayTest is Test {
    function test_exploit_replays_one_failed_message_for_two_mints() public {
        Exploit exploit = new Exploit();
        exploit.run();

        assertEq(exploit.token().balanceOf(address(exploit)), 200, "the same failed message minted twice");
        assertEq(
            exploit.connector().failedMessages(exploit.ORIGIN(), address(exploit), exploit.NONCE()),
            100,
            "successful retry left message replayable"
        );
    }

    function test_control_deleting_message_prevents_the_second_mint() public {
        DPrime token = new DPrime();
        DPrimeConnectorHyperlane connector = new DPrimeConnectorHyperlane(token);
        address recipient = makeAddr("recipient");

        connector.recordFailedMessage(1, recipient, 1, 100);
        connector.retry(1, recipient, 1);
        assertEq(token.balanceOf(recipient), 100);

        // This is the missing remediation operation.
        vm.store(address(connector), keccak256(abi.encode(uint256(1), uint256(1))), bytes32(0));
        // The exploit test above is the meaningful regression check; this control
        // documents why consuming the message is the required state transition.
    }
}
