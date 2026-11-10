// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    RewardToken,
    CasimirRegistry,
    CasimirManager,
    CasimirManagerFixed
} from "./35002-operator-is-not-removed-in-registry-when-validator-has-oweda.sol";

contract Finding35002Test is Test {
    function test_exploit_full_withdrawal_still_pays_removed_operator() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.manager().countedAfterExit(), 1, "removed operator still counted");
        assertEq(e.registry().validatorCount(1), 1, "validatorCount");
        assertEq(e.registry().totalValidatorCount(), 2, "both operators still in the registry");
        assertEq(e.manager().paidRemoved(), 2 ether, "distribution paid the removed operator 2 ETH");
        assertEq(e.token().balanceOf(e.manager().OLD_OPERATOR()), 2 ether, "old operator balance");
        assertEq(e.token().balanceOf(e.manager().KEEPER_OPERATOR()), 2 ether, "keeper was diluted");
    }

    function test_control_zero_owed_removes_operator_and_skips_payment() public {
        RewardToken token = new RewardToken();
        CasimirRegistry registry = new CasimirRegistry();
        CasimirManagerFixed fixedManager = new CasimirManagerFixed(token, registry);
        token.mint(address(fixedManager), 4 ether);

        registry.seedOperator(fixedManager.REMOVED(), fixedManager.OLD_OPERATOR());
        registry.seedOperator(fixedManager.KEEPER(), fixedManager.KEEPER_OPERATOR());
        fixedManager.seedValidator(7, fixedManager.REMOVED());
        fixedManager.withdrawValidator(7, 32 ether);

        assertEq(registry.validatorCount(fixedManager.REMOVED()), 0, "control left the operator registered");
        assertEq(registry.totalValidatorCount(), 1, "control total");

        fixedManager.distribute(4 ether);

        assertEq(fixedManager.paidRemoved(), 0, "control still computed a payment");
        assertEq(token.balanceOf(fixedManager.OLD_OPERATOR()), 0, "control paid the removed operator");
        assertEq(token.balanceOf(fixedManager.KEEPER_OPERATOR()), 4 ether, "keeper did not receive the full reward");
    }
}
