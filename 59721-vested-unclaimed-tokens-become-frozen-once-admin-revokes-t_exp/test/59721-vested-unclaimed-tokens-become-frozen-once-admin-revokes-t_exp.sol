// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Exploit, MiniToken, FixedTokenVesting} from "./59721-vested-unclaimed-tokens-become-frozen-once-admin-revokes-t.sol";

contract Vesting59721Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_vested_tokens_frozen_after_revoke() public {
        Exploit e = new Exploit();
        e.run();

        // grantee had 50 tokens vested at revocation time
        assertEq(e.claimableBefore(), 50, "50 should be vested at half-way point");
        assertEq(e.claimableAfterRevoke(), 50, "vested amount preserved through revoke");

        // withdraw() reverted for the revoked grantee -> vested tokens unreachable
        assertTrue(e.withdrawReverted(), "withdraw must revert (NO_ACTIVE_GRANT)");
        assertEq(e.granteeBalAfter(), 0, "grantee received nothing");

        // the 50 vested tokens are still reserved but withdrawable by no one -> frozen
        assertEq(e.stuckReserved(), 50, "50 tokens permanently reserved/frozen");

        // harm magnitude recorded to SINK via marker token
        MiniToken marker = e.marker();
        assertEq(marker.balanceOf(SINK), 50, "frozen magnitude of 50 minted to SINK");
        assertEq(e.frozenVested(), 50);
    }

    function test_control_fixed_allows_revoked_grantee_withdraw() public {
        MiniToken token = new MiniToken();
        FixedTokenVesting v = new FixedTokenVesting(token); // admin = this test contract
        token.mint(address(v), 100);

        address grantee = address(0xBEEF);

        // start=0, end=2*now => 50% vested at current block
        v.createGrant(grantee, 0, uint40(block.timestamp) * 2, 100, 0);
        assertEq(v.claimableAmount(grantee), 50);

        // admin revokes half-way
        v.revokeGrant(grantee);
        assertEq(v.claimableAmount(grantee), 50, "vested amount still owed");

        // FIX: revoked grantee can still withdraw the already-vested tokens
        vm.prank(grantee);
        v.withdraw();

        assertEq(token.balanceOf(grantee), 50, "grantee recovers vested 50 tokens");
        assertEq(v.numTokensReservedForVesting(), 0, "no tokens left frozen");
    }
}
