// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {
    CollateralToken,
    Exploit,
    GroupVault,
    GroupVaultFixed
} from "./62868-missing-debt-validation-in-group-burn-function-trailofbits-n.sol";

contract Finding62868Test is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    function test_burn_leaves_debt_and_extracts_collateral() public {
        Exploit e = new Exploit();
        vm.prank(ATTACKER);
        e.run();

        GroupVault vault = e.vault();
        CollateralToken token = e.token();

        assertEq(vault.unsettledDebt(), 2, "debt left");
        assertEq(vault.badDebt(), 200 ether, "bad debt");
        assertEq(token.balanceOf(ATTACKER), 400 ether, "extracted");
        assertEq(vault.erc1155Balance(address(e), 1), 1, "erc1155");
        assertEq(vault.groupBalance(address(e), 1, 0), 3, "expired group untouched");
        assertEq(vault.groupBalance(address(e), 1, 1), 0, "live group cleared");
        assertEq(vault.groupSum(address(e), 1), 3, "group ledger");
        assertEq(token.balanceOf(address(vault)), 100 ether, "treasury");

        console2.log("unsettled debt", vault.unsettledDebt());
        console2.log("bad debt", vault.badDebt());
        console2.log("extracted", token.balanceOf(ATTACKER));
        console2.log("treasury left", token.balanceOf(address(vault)));
    }

    function test_control_reverts_while_debt_remains() public {
        CollateralToken token = new CollateralToken();
        GroupVaultFixed fixedVault = new GroupVaultFixed(token);
        token.mint(address(fixedVault), 500 ether);
        fixedVault.seed(address(this), 1);

        vm.expectRevert(bytes("DEBT"));
        fixedVault.burn(address(this), 1, 4);

        assertEq(token.balanceOf(address(this)), 0, "no collateral released");
        assertEq(token.balanceOf(address(fixedVault)), 500 ether, "treasury intact");
        assertEq(fixedVault.erc1155Balance(address(this), 1), 5, "erc1155 unchanged");
        assertEq(fixedVault.groupBalance(address(this), 1, 0), 3, "expired group");
        assertEq(fixedVault.groupBalance(address(this), 1, 1), 2, "live group");
        assertEq(fixedVault.unsettledDebt(), 0, "revert rolled the write back");

        console2.log("control revert", uint256(1));
        console2.log("control treasury", token.balanceOf(address(fixedVault)));
    }

    function test_control_exact_live_burn_succeeds() public {
        CollateralToken token = new CollateralToken();
        GroupVaultFixed fixedVault = new GroupVaultFixed(token);
        token.mint(address(fixedVault), 500 ether);
        fixedVault.seed(address(this), 1);

        fixedVault.burn(address(this), 1, 2);

        assertEq(token.balanceOf(address(this)), 200 ether, "only live collateral");
        assertEq(fixedVault.unsettledDebt(), 0, "debt cleared");
        assertEq(fixedVault.erc1155Balance(address(this), 1), 3, "two tokens burned");
        assertEq(token.balanceOf(address(fixedVault)), 300 ether, "treasury");

        console2.log("control live payout", token.balanceOf(address(this)));
    }
}
