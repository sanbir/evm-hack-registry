// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, CardValue, Card, Packet, Pool, Manager, Honest} from
    "./62592-c-01-reentrancy-attack-in-authorizedopenpacket-allows-duplic.sol";

contract Finding62592Test is Test {
    function test_exploit_opens_one_packet_twice() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.card().balanceOf(address(e)), 2, "two cards");
        assertEq(e.token().balanceOf(address(e)), 200e18, "200 paid");
        assertEq(e.packet().finalized(), 2, "two finalizes");
    }

    function test_control_honest_receiver_is_paid_once() public {
        CardValue token = new CardValue();
        Card card = new Card();
        Packet packet = new Packet();
        Pool pool = new Pool(card, packet, token);
        Manager manager = new Manager();
        Honest honest = new Honest(packet, manager, pool);
        packet.setPool(address(pool));
        packet.setInventory(address(0xBEEF));
        packet.mint(address(honest), 7);
        token.mint(address(pool), 200e18);

        honest.open(7);

        assertEq(card.balanceOf(address(honest)), 1, "one card");
        assertEq(token.balanceOf(address(honest)), 100e18, "paid once");
        assertEq(packet.finalized(), 1, "one finalize");
        assertEq(token.balanceOf(address(pool)), 100e18, "second set remains");
    }
}
