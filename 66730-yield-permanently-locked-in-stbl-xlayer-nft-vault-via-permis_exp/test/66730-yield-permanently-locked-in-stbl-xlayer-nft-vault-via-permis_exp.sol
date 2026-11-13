// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, RewardToken, YToken, YieldDistributor, NftVault, Manager} from
    "./66730-yield-permanently-locked-in-stbl-xlayer-nft-vault-via-permis.sol";

contract Finding66730Test is Test {
    function test_exploit_permissionless_claim_strands_1000() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.stranded(), 1000 ether, "stranded");
        assertEq(e.managerGot(), 0, "manager got 0");
        assertEq(e.token().balanceOf(address(e.vault())), 1000 ether, "vault holds 1000");
        assertEq(e.token().balanceOf(address(e.manager())), 0, "manager empty");
        assertEq(e.distributor().earned(1), 0, "earned consumed");
        assertEq(e.vault().lastPaid(), 0, "delta was 0");
    }

    function test_control_vault_only_claim_pays_manager() public {
        RewardToken token = new RewardToken();
        YToken ytoken = new YToken();
        YieldDistributor distributor = new YieldDistributor(token, ytoken);
        Manager manager = new Manager();
        NftVault vault = new NftVault(token, distributor, address(manager), 1);
        distributor.setVault(address(vault));
        distributor.setOnlyVault(true);
        ytoken.mint(address(vault), 1);

        token.mint(address(this), 1000 ether);
        token.approve(address(distributor), 1000 ether);
        distributor.fund(1, 1000 ether);

        vm.expectRevert(bytes("vault"));
        distributor.claim(1);

        uint256 paid = manager.collect(vault, 0);
        assertEq(paid, 1000 ether, "manager paid");
        assertEq(token.balanceOf(address(manager)), 1000 ether, "manager holds 1000");
        assertEq(token.balanceOf(address(vault)), 0, "vault empty");
    }
}
