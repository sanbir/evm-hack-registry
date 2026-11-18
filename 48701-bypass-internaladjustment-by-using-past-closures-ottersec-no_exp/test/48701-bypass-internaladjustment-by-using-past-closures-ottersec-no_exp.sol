// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./48701-bypass-internaladjustment-by-using-past-closures-ottersec-no.sol";
import {Asset, Vault} from "./48701-bypass-internaladjustment-by-using-past-closures-ottersec-no.sol";

contract Finding48701Test is Test {

    function test_exploit_withdraws_120_instead_of_90() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.withdrawn(), 120 ether, "inflated");
        assertEq(e.made(), 8, "quota");
        assertEq(e.asset().balanceOf(address(this)), 120 ether, "paid");
    }

    function test_control_past_ids_do_not_count() public {
        Asset asset = new Asset();
        Vault fixedVault = new Vault(asset, true);
        fixedVault.loadClosures();
        fixedVault.buy(address(this), 1);
        assertFalse(fixedVault.adjustTicketInfo(address(this), 1, 1));
        assertFalse(fixedVault.adjustTicketInfo(address(this), 1, 2));
        assertFalse(fixedVault.adjustTicketInfo(address(this), 1, 3));
        (, , uint256 made) = _made(fixedVault);
        assertEq(fixedVault.adjustmentsMade(address(this), 1), 3, "past ignored");
        fixedVault.adjustTicketInfo(address(this), 1, 4);
        fixedVault.adjustTicketInfo(address(this), 1, 5);
        fixedVault.adjustTicketInfo(address(this), 1, 6);
        fixedVault.adjustTicketInfo(address(this), 1, 7);
        fixedVault.adjustTicketInfo(address(this), 1, 8);
        uint256 got = fixedVault.sell(address(this), 1);
        assertEq(got, 90 ether, "fair");
        assertEq(asset.balanceOf(address(fixedVault)), 30 ether, "losses stayed");
        made = got;
        made;
    }

    function _made(Vault) internal pure returns (uint256, uint256, uint256) {
        return (0, 0, 0);
    }

}
