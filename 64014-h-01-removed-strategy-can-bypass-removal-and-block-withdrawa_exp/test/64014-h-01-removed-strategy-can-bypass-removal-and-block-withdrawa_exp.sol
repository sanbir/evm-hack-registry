// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, ERC20Mini, StrategyRegistry, PairStrategy, VaultFixed, StrategyKind} from "./64014-h-01-removed-strategy-can-bypass-removal-and-block-withdrawa.sol";

contract Finding64014Test is Test {
    function test_exploit_removed_pair_reverts_withdraw_and_locks_tokens() public {
        Exploit e = new Exploit();
        e.run();
        assertFalse(e.withdrew(), "withdrew");
        assertTrue(e.stillLocked(), "not locked");
        assertEq(e.kindAfter(), 0, "kind");
        assertFalse(e.activeAfter(), "active");
        assertEq(e.token().balanceOf(address(e.pairStrat())), 1000 ether, "stuck");
        assertEq(e.token().balanceOf(address(e.user())), 0, "user");
    }

    function test_control_inactive_strategy_is_skipped_and_idle_pays() public {
        ERC20Mini token = new ERC20Mini();
        StrategyRegistry reg = new StrategyRegistry();
        PairStrategy strat = new PairStrategy(token);
        VaultFixed vault = new VaultFixed(reg, token, address(strat));
        reg.addStrategy(address(strat), StrategyKind.PairAsset);
        vault.addPriority(StrategyKind.PairAsset, address(strat));
        reg.removeStrategy(address(strat));
        token.mint(address(vault), 1000 ether);
        vault.withdraw(1000 ether);
        assertEq(token.balanceOf(address(this)), 1000 ether, "paid");
    }
}
