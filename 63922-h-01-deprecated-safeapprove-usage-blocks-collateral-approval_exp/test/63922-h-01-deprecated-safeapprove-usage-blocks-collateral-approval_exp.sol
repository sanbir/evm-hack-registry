// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    CollateralExecutor,
    CollateralExecutorFixed,
    CollateralAction,
    MiniToken,
    MockPool,
    IPool,
    IERC20
} from "./63922-h-01-deprecated-safeapprove-usage-blocks-collateral-approval.sol";

contract DeprecatedSafeApproveCollateralDosTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ATOKEN = address(0xA70C);
    address internal constant USER = address(0xBEEF);

    uint256 internal constant AMOUNT = 100 ether;
    string internal constant EXPECTED_REVERT = "SafeERC20: approve from non-zero to non-zero allowance";

    // The exploit driver reproduces the full DoS + negative control end to end.
    function test_exploit_safeApproveBricksSecondCollateralSupply() public {
        Exploit e = new Exploit();
        e.run();

        // 1) The first collateral supply succeeds through the real safeApprove path.
        assertTrue(e.vulnFirstCallOk(), "first collateral supply should succeed");

        // 2) The residual executor->pool allowance is non-zero (max - amount): this
        //    is exactly what makes the deprecated safeApprove revert next time.
        assertEq(
            e.allowanceAfterFirst(),
            type(uint256).max - AMOUNT,
            "pool allowance must remain non-zero after the first supply"
        );

        // 3) The second collateral supply for the SAME token reverts permanently
        //    inside safeApprove -> liveness DoS.
        assertTrue(e.vulnSecondCallReverted(), "second collateral supply must revert (DoS)");
        assertEq(e.vulnRevertReason(), EXPECTED_REVERT, "revert must be the safeApprove non-zero->non-zero error");

        // 4) Harm marker: AMOUNT collateral is now permanently un-suppliable per call.
        assertEq(e.blockedAmount(), AMOUNT, "blocked collateral magnitude");
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), AMOUNT, "SINK marker records the bricked collateral amount");

        // 5) Negative control: the forceApprove fix allows repeated supply.
        assertTrue(e.fixedFirstCallOk(), "fixed variant: first supply ok");
        assertTrue(e.fixedSecondCallOk(), "fixed variant: second supply ok");
    }

    // Direct, cheatcode-based reproduction against the vulnerable executor: the
    // second executeOperation for the same token reverts with the exact reason.
    function test_direct_secondExecuteOperationReverts() public {
        MiniToken collateral = new MiniToken("Collateral", "COLL");
        MockPool pool = new MockPool(ATOKEN);
        CollateralExecutor executor = new CollateralExecutor(IPool(address(pool)));

        deal(USER, 0);
        collateral.mint(USER, 10 * AMOUNT);
        vm.prank(USER);
        collateral.approve(address(executor), type(uint256).max);

        CollateralAction[] memory actions = new CollateralAction[](1);
        actions[0] = CollateralAction({token: IERC20(address(collateral)), amount: AMOUNT});

        // First supply works: collateral escrowed into the aToken vault.
        vm.prank(USER);
        executor.executeOperation(actions);
        assertEq(collateral.balanceOf(ATOKEN), AMOUNT, "first supply escrowed collateral");
        assertEq(
            collateral.allowance(address(executor), address(pool)),
            type(uint256).max - AMOUNT,
            "residual non-zero pool allowance"
        );

        // Second supply reverts on the deprecated safeApprove -> permanent DoS.
        vm.prank(USER);
        vm.expectRevert(bytes(EXPECTED_REVERT));
        executor.executeOperation(actions);

        // No additional collateral could be escrowed: the vault balance is unchanged.
        assertEq(collateral.balanceOf(ATOKEN), AMOUNT, "no further collateral could be supplied");
    }

    // Negative control (direct): the forceApprove fix supplies repeatedly.
    function test_direct_fixedExecutorAllowsRepeatedSupply() public {
        MiniToken collateral = new MiniToken("Collateral", "COLL");
        MockPool pool = new MockPool(ATOKEN);
        CollateralExecutorFixed executor = new CollateralExecutorFixed(IPool(address(pool)));

        collateral.mint(USER, 10 * AMOUNT);
        vm.prank(USER);
        collateral.approve(address(executor), type(uint256).max);

        CollateralAction[] memory actions = new CollateralAction[](1);
        actions[0] = CollateralAction({token: IERC20(address(collateral)), amount: AMOUNT});

        vm.prank(USER);
        executor.executeOperation(actions);
        vm.prank(USER);
        executor.executeOperation(actions);

        assertEq(collateral.balanceOf(ATOKEN), 2 * AMOUNT, "fixed variant escrowed both supplies");
    }
}
