// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Coll, Core, Exploit, Victim} from "./37520-minted-cetokens-not-added-to-users-list-if-minted-using-repa.sol";

/// Report's fix: an overpaying repay records the minted ceToken on the user.
contract CoreFixed is Core {
    constructor(Coll _coll) Core(_coll) {}

    function repay(uint256 payment) external override {
        uint256 owed = debt[msg.sender];
        uint256 pay = payment > owed ? owed : payment;
        debt[msg.sender] = owed - pay;
        uint256 excess = payment - pay;
        if (excess != 0) {
            balance[msg.sender][CE_ID] += excess;
            _addToken(msg.sender, CE_ID);
        }
    }
}

contract Finding37520Test is Test {
    function test_exploit_unlisted_cetokens_let_a_healthy_user_be_liquidated() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.coll().balanceOf(address(e)), 100 ether, "liquidator seized 100 COLL");
        assertEq(e.core().balance(address(e.victim()), 1), 0, "victim collateral cleared");
        assertEq(e.core().balance(address(e.victim()), 2), 50 ether, "50 ceTokens still unlisted");
        assertEq(e.core().debt(address(e.victim())), 0, "debt wiped by liquidation");
    }

    function test_control_listed_cetokens_block_liquidation() public {
        Coll coll = new Coll();
        CoreFixed fixedCore = new CoreFixed(coll);
        Victim victim = new Victim();
        coll.mint(address(victim), 100 ether);

        victim.approveAndDeposit(coll, Core(address(fixedCore)), 100 ether);
        victim.borrow(Core(address(fixedCore)), 200 ether);
        victim.repay(Core(address(fixedCore)), 250 ether);
        victim.borrow(Core(address(fixedCore)), 120 ether);

        assertEq(fixedCore.balance(address(victim), 2), 50 ether, "ceTokens minted");
        assertEq(fixedCore.listed(address(victim)), 2, "ceToken id was recorded");
        (uint256 seen, uint256 owed) = fixedCore.healthFactor(address(victim));
        assertEq(seen, 150 ether, "health counts 100 collateral plus 50 ceTokens");
        assertEq(owed, 120 ether, "new debt is 120");

        vm.expectRevert(Core.Healthy.selector);
        fixedCore.liquidate(address(victim));
        assertEq(coll.balanceOf(address(this)), 0, "liquidator received nothing");
        assertEq(fixedCore.balance(address(victim), 1), 100 ether, "victim kept the collateral");
    }
}
