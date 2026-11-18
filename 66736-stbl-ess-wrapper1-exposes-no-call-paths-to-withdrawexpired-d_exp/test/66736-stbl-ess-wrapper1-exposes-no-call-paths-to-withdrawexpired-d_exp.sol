// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, MockToken, Treasury, Issuer, AssetVault, FixedWrapper} from
    "./66736-stbl-ess-wrapper1-exposes-no-call-paths-to-withdrawexpired-d.sol";

contract Finding66736Test is Test {
    function test_exploit_expired_assets_yield_and_fees_stay_locked() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.token().balanceOf(address(e.vault())), 1065 ether, "vault holds deposit, fee, and yield");
        assertEq(e.token().balanceOf(address(e.treasury())), 0, "treasury received nothing");
        assertEq(e.vault().locked(), 1000 ether, "expired LT assets");
        assertEq(e.vault().fees(), 40 ether, "fees stranded");
        assertEq(e.vault().yieldAccrued(), 25 ether, "yield undistributed");
    }

    function test_control_passthrough_releases_fees_and_expired_assets() public {
        MockToken token = new MockToken();
        Treasury treasury = new Treasury();
        Issuer issuer = new Issuer();
        AssetVault vault = new AssetVault();
        FixedWrapper fixedWrapper = new FixedWrapper(issuer, vault);
        issuer.init(address(fixedWrapper), token, address(treasury));
        vault.init(address(fixedWrapper), token, address(treasury));

        token.mint(address(issuer), 1000 ether);
        token.mint(address(vault), 65 ether);
        vm.prank(address(fixedWrapper));
        vault.note(1000 ether, 40 ether, 25 ether);
        vm.prank(address(fixedWrapper));
        issuer.note(1000 ether);

        fixedWrapper.distributeYield();
        fixedWrapper.withdrawFees();
        fixedWrapper.withdrawExpired(1);

        assertEq(vault.yieldAccrued(), 0, "yield was distributed");
        assertEq(token.balanceOf(address(treasury)), 1000 ether + 40 ether, "treasury received assets and fees");
    }
}
