// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, FantiumNFT, FantiumMinterV1} from
    "./28050-undefined-behavior-for-mint-mixbytes-none-fantium-markdown.sol";

contract Finding28050Test is Test {
    address internal constant ATHLETE = address(0x90F79bf6EB2c4f870365E785982E1f101E93b906);

    function test_mint_ignores_the_recipient() public {
        Exploit e = new Exploit();
        vm.deal(address(this), 100000000000000);
        e.run{value: 100000000000000}();
        assertEq(e.nft().ownerOf(1000000), address(e), "fan");
        assertEq(e.nft().balanceOf(ATHLETE), 0, "athlete");
        console2.log("fan balance", e.nft().balanceOf(address(e)));
        console2.log("athlete balance", e.nft().balanceOf(ATHLETE));
    }

    function test_control_mintTo_gives_the_athlete_the_token() public {
        FantiumNFT nft = new FantiumNFT();
        FantiumMinterV1 minter = new FantiumMinterV1(nft);
        vm.deal(address(this), 100000000000000);
        minter.mintFixed{value: 100000000000000}(ATHLETE, 1);
        assertEq(nft.ownerOf(1000000), ATHLETE, "athlete owns it");
        assertEq(nft.balanceOf(address(this)), 0, "caller has 0");
        console2.log("control athlete balance", nft.balanceOf(ATHLETE));
    }
}
