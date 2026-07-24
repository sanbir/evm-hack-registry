// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./62847-c-01-sessionkey-owner-drain-smart-wallet.sol";

contract PoC_62847 is Test {
    function test_session_owner_can_drain_unlocked_wallet_tokens() public {
        Exploit exploit = new Exploit();
        exploit.run();
        assertEq(exploit.drained(), 1_000);
        assertEq(exploit.token().balanceOf(address(exploit.wallet())), 0);
    }
}
