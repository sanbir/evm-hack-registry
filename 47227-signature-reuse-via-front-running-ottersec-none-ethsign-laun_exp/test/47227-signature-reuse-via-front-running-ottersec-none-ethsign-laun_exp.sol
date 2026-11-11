// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    MockToken,
    NFTSimpleAuctionFixed
} from "./47227-signature-reuse-via-front-running-ottersec-none-ethsign-laun.sol";

contract Finding47227Test is Test {
    address internal constant INTENDED = 0x2222222222222222222222222222222222222222;
    address internal constant SIGNER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    bytes32 internal constant CODE = 0x000000000000000000000000000000000000000000000000000000000000c0de;
    bytes internal constant SIG =
        hex"b27d30dd672db1afd121bd93989fc51b835a4ba235354c35be3cbdc6324ff2b9610380b492ae804c2e50eaae4c084ad946e318d9abccc9effeac785ed8230bfd1b";

    function test_exploit_attacker_mints_nfts_signed_for_someone_else() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.attackerMinted(), 5, "attacker minted N");
        assertEq(e.intendedMinted(), 0, "intended buyer got nothing");
        assertEq(e.wl().balanceOf(address(e)), 5, "5 NFTs sit with the attacker");
        assertTrue(e.auction()._usedCodes(e.DIGEST()), "code consumed");
    }

    function test_control_binding_msg_sender_reverts_for_attacker() public {
        MockToken wl = new MockToken();
        NFTSimpleAuctionFixed auction = new NFTSimpleAuctionFixed(SIGNER, wl);
        bytes memory extra = abi.encode(uint256(5), CODE, SIG);

        vm.expectRevert(NFTSimpleAuctionFixed.InvalidSignature.selector);
        auction.purchase(5, extra);

        assertEq(wl.balanceOf(address(this)), 0, "attacker minted nothing");

        vm.prank(INTENDED);
        auction.purchase(5, extra);
        assertEq(wl.balanceOf(INTENDED), 5, "intended buyer can still use their own signature");
        assertEq(wl.balanceOf(address(this)), 0, "attacker still has nothing");
    }
}
