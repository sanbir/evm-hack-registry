// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    GatewayFixed,
    Sink,
    Gateway
} from "./19279-operations-are-vulnerable-to-signature-replay-via-reentrancy.sol";

contract Finding19279Test is Test {
    function test_one_signature_pays_twice() public {
        Exploit e = new Exploit();
        assertEq(
            e.gateway().recover(1 ether, 0, e.V(), e.R(), e.S()),
            e.gateway().OWNER(),
            "precomputed signature"
        );
        vm.deal(address(this), 2 ether);
        e.run{value: 2 ether}();
        assertEq(e.received(), 2 ether, "one signature paid 2 ether");
        assertEq(address(e.sink()).balance, 2 ether, "sink holds both payments");
        assertEq(address(e.gateway()).balance, 0, "wallet was drained of the 2 ether");
        assertEq(e.gateway().nonce(), 2, "both calls incremented");
    }

    function test_control_nonce_before_call_pays_once() public {
        uint256 pk = 0x80f5ed7770667c80ced25a2b7fcee9b6e716efead38963f25436920160a83505;
        GatewayFixed gateway = new GatewayFixed();
        Sink sink = new Sink();
        bytes32 inner = keccak256(abi.encode(uint256(0), uint256(1 ether)));
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", inner));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        vm.deal(address(this), 2 ether);
        gateway.fund{value: 2 ether}();
        sink.arm(gateway, address(sink), 1 ether, v, r, s);
        gateway.process(address(sink), 1 ether, v, r, s);

        assertTrue(sink.replayed(), "reentry was attempted");
        assertEq(address(sink).balance, 1 ether, "second payment did not land");
        assertEq(gateway.nonce(), 1, "nonce consumed once");
        assertEq(address(gateway).balance, 1 ether, "the other ether stayed in the wallet");
    }
}
