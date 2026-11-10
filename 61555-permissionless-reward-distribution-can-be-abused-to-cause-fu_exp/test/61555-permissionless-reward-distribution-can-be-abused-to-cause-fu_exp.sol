// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    LogicFixed,
    Token
} from "./61555-permissionless-reward-distribution-can-be-abused-to-cause-fu.sol";

contract Rejector {
    function tryDeposit(LogicFixed logic, Token reward, uint256 amount, uint256 duration) external returns (bool) {
        reward.approve(address(logic), amount);
        try logic.depositRewards(amount, duration) {
            return true;
        } catch {
            return false;
        }
    }
}

contract Finding61555Test is Test {
    function test_exploit_staker_receives_zero_of_locked_lp() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.rate(), type(uint96).max, "permissionless notify set uint96 max rate");
        assertTrue(e.removeReverted(), "remove reverts");
        assertTrue(e.claimReverted(), "claim reverts");
        assertEq(e.stakerLp(), 0, "staker receives 0");
        assertEq(e.locked(), e.N(), "N LP stays in the logic");
        assertEq(e.lp().balanceOf(address(e.logic())), 1 ether, "1 LP locked");
    }

    function test_control_allowlist_lets_staker_withdraw() public {
        Token lp = new Token("Liquidity", "LP", 18);
        Token reward = new Token("Malicious", "MAL", 18);
        LogicFixed logic = new LogicFixed(lp, reward, address(this));
        uint256 n = 1 ether;
        lp.mint(address(this), n);
        lp.approve(address(logic), n);
        logic.stake(n);

        uint256 amount = uint256(type(uint96).max) * 1 weeks;
        Rejector rejector = new Rejector();
        reward.mint(address(rejector), amount);
        bool accepted = rejector.tryDeposit(logic, reward, amount, 1 weeks);
        assertFalse(accepted, "non-admin notify rejected");

        uint256 back = logic.removeLiquidity(n);
        assertEq(back, n, "control withdraws N");
        assertEq(lp.balanceOf(address(this)), n, "staker received N");
        assertEq(lp.balanceOf(address(logic)), 0, "nothing left locked");
    }
}
