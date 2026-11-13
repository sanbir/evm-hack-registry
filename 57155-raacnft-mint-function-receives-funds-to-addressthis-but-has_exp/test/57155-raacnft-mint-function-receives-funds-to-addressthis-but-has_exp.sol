// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, HousePrices, RAACNFTFixed} from
    "./57155-raacnft-mint-function-receives-funds-to-addressthis-but-has.sol";

contract Finding57155Test is Test {
    function test_exploit_mint_price_locks_5_crvusd_in_the_nft() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.locked(), 5 ether, "5 locked");
        assertEq(e.token().balanceOf(address(e.nft())), 5 ether, "nft holds the price");
        assertEq(e.token().balanceOf(address(e)), 2 ether, "only the overpay came back");
        assertEq(e.nft().ownerOf(2), address(e), "nft minted");
    }

    function test_control_price_is_forwarded_and_the_nft_holds_zero() public {
        Token token = new Token();
        HousePrices oracle = new HousePrices();
        address receiver = address(0xBEEF);
        RAACNFTFixed nft = new RAACNFTFixed(token, oracle, receiver);
        oracle.setHousePrice(2, 5 ether);
        token.mint(address(this), 7 ether);
        token.approve(address(nft), 7 ether);
        nft.mint(2, 7 ether);

        assertEq(token.balanceOf(address(nft)), 0, "nft empty");
        assertEq(token.balanceOf(receiver), 5 ether, "receiver got the price");
        assertEq(token.balanceOf(address(this)), 2 ether, "overpay stayed with the buyer");
        assertEq(nft.ownerOf(2), address(this), "minted");
    }
}
