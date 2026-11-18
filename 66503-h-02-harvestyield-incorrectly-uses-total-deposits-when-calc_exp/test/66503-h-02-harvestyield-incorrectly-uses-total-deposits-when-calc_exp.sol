// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, VaultYield, Receiver} from "./66503-h-02-harvestyield-incorrectly-uses-total-deposits-when-calc.sol";

contract Finding66503Test is Test {
    function test_exploit_harvest_books_principal() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.booked(), 0.1 ether, "booked 0.1");
        assertEq(e.fairYield(), 0.095 ether, "fair 0.095");
        assertEq(e.assetsLeft(), 0.945 ether, "principal reduced");
    }

    function test_control_share_base_leaves_principal() public {
        Token asset = new Token("asset");
        Receiver pool = new Receiver(asset);
        VaultYield vault = new VaultYield(asset, address(pool));
        asset.mint(address(vault), 1.045 ether);
        vault.load(0.95 ether, 1.045 ether, 0.95 ether, 1 ether);
        vault.harvest();
        assertEq(vault.unclaimedRewards(), 0.095 ether, "yield matches shares");
        assertEq(vault.assets(), 0.95 ether, "principal remains");
    }
}
