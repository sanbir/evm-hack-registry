// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
import "forge-std/Test.sol";
import {Exploit, Asset, NativeVault, Alice} from "./38492-h-04-increasebalance-mints-fewer-shares-than-expected-pasho.sol";

contract Finding38492Test is Test {
    function test_exploit_alice_minted_half_the_shares() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.vault().balanceOf(address(e.alice())), 16 ether, "16 shares");
        assertEq(e.asset().balanceOf(address(e)), 10666666666666666666, "profit");
        assertEq(e.asset().balanceOf(address(e.sink())), 32 ether, "principal parked");
        assertEq(e.vault().previewRedeem(16 ether), 21333333333333333334, "alice dust after redeem");
    }

    function test_control_fixed_order_keeps_one_to_one() public {
        Asset asset = new Asset();
        NativeVault vault = new NativeVault(asset);
        Alice alice = new Alice(vault, asset);
        asset.mint(address(vault), 32 ether);
        vault.bootstrap(address(this), 32 ether);
        asset.mint(address(alice), 32 ether);
        alice.approve();
        alice.depositFixed(32 ether);
        assertEq(vault.balanceOf(address(alice)), 32 ether, "full shares");
        uint256 got = vault.redeem(32 ether);
        assertEq(got, 32 ether, "old holder unchanged");
        assertEq(vault.previewRedeem(vault.balanceOf(address(alice))), 32 ether, "alice whole");
    }
}
