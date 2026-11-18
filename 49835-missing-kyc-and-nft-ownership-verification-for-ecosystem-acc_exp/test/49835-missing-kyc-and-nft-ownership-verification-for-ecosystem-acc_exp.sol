// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    ERC20,
    Exploit,
    MembershipFactoryFixed,
    OWPIdentity
} from "./49835-missing-kyc-and-nft-ownership-verification-for-ecosystem-acc.sol";

contract Finding49835Test is Test {
    function test_unverified_user_takes_the_only_membership() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.membership().balanceOf(address(e)), 1, "unverified membership minted");
        assertEq(e.factory().tierMinted(), 1, "tier cap consumed");
        assertFalse(e.identity().isKYC(address(e)), "still not KYC");
        assertEq(e.ecosystemNft().balanceOf(address(e)), 0, "still no ecosystem NFT");
    }

    function test_control_kyc_and_nft_are_required() public {
        ERC20 currency = new ERC20("OWP", "OWP", 18);
        ERC20 membership = new ERC20("DAO Membership", "MEMBER", 0);
        ERC20 nft = new ERC20("Ecosystem NFT", "OWNFT", 0);
        OWPIdentity identity = new OWPIdentity();
        MembershipFactoryFixed fixedFactory = new MembershipFactoryFixed(membership, currency, nft, identity, address(0xCAFE));
        currency.mint(address(this), 100 ether);
        currency.approve(address(fixedFactory), 100 ether);
        vm.expectRevert(bytes("KYC"));
        fixedFactory.joinDAO(address(fixedFactory), 0);
        identity.setKYC(address(this), true);
        vm.expectRevert(bytes("ecosystem NFT"));
        fixedFactory.joinDAO(address(fixedFactory), 0);
        assertEq(membership.balanceOf(address(this)), 0, "no membership without both checks");
    }
}
