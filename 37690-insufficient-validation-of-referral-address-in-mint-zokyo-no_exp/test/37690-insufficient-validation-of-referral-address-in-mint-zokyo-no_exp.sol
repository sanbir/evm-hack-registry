// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    NftFixed
} from "./37690-insufficient-validation-of-referral-address-in-mint-zokyo-no.sol";

contract Finding37690Test is Test {
    address internal constant REAL = 0x3333333333333333333333333333333333333333;

    function test_exploit_self_referral_keeps_the_fee() public {
        vm.deal(address(this), 2 ether);
        Exploit e = new Exploit();
        e.run{value: 1 ether}();

        assertEq(address(e).balance, 0.1 ether, "minter kept the 0.1 ETH referral fee");
        assertEq(REAL.balance, 0, "the real referrer was paid nothing");
        assertEq(address(e.nft()).balance, 0.9 ether, "the contract kept the other 0.9 ETH");
        assertEq(e.nft().minted(address(e)), 1, "the NFT was minted");
    }

    function test_control_rejects_bad_referrals_and_pays_the_real_one() public {
        vm.deal(address(this), 4 ether);
        NftFixed nft = new NftFixed(REAL);

        (bool selfOk,) = address(nft).call{value: 1 ether}(
            abi.encodeWithSignature("mint(address)", address(this))
        );
        assertFalse(selfOk, "self-referral is rejected");

        (bool zeroOk,) = address(nft).call{value: 1 ether}(
            abi.encodeWithSignature("mint(address)", address(0))
        );
        assertFalse(zeroOk, "address(0) is rejected");

        nft.mint{value: 1 ether}(REAL);
        assertEq(REAL.balance, 0.1 ether, "the authorized referrer received 0.1 ETH");
        assertEq(address(nft).balance, 0.9 ether, "the contract kept 0.9 ETH");
        assertEq(nft.minted(address(this)), 1, "one NFT minted");
    }
}
