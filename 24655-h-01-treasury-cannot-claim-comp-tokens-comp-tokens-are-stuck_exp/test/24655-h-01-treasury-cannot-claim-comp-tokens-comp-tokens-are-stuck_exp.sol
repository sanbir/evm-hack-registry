// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, MiniToken, Comptroller} from "./24655-h-01-treasury-cannot-claim-comp-tokens-comp-tokens-are-stuck.sol";

contract TreasuryActionFixed {
    MiniToken public COMP;
    address public treasuryManager;

    constructor(address _comp, address _treasury) {
        COMP = MiniToken(_comp);
        treasuryManager = _treasury;
    }

    function claimCOMPAndTransfer() external returns (uint256) {
        uint256 amountClaimed = COMP.balanceOf(address(this));
        if (amountClaimed != 0) COMP.transfer(treasuryManager, amountClaimed);
        return amountClaimed;
    }
}

contract Finding24655Test is Test {
    function test_exploit_comp_stuck_after_permissionless_claim() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.harvested(), 0, "delta harvest is zero");
        assertEq(e.comp().balanceOf(e.TREASURY()), 0, "treasury unpaid");
        assertEq(e.comp().balanceOf(address(e.action())), e.STUCK(), "1000 COMP stuck");
    }

    function test_control_full_balance_harvest_forwards_preclaimed_comp() public {
        MiniToken comp = new MiniToken("Compound", "COMP");
        Comptroller comptroller = new Comptroller(address(comp));
        address treasury = address(0xD00D);
        TreasuryActionFixed action = new TreasuryActionFixed(address(comp), treasury);
        comp.mint(address(comptroller), 1000e18);
        address[] memory none = new address[](0);
        comptroller.claimComp(address(action), none);
        uint256 harvested = action.claimCOMPAndTransfer();
        assertEq(harvested, 1000e18, "full balance forwarded");
        assertEq(comp.balanceOf(treasury), 1000e18, "treasury paid");
        assertEq(comp.balanceOf(address(action)), 0, "nothing stuck");
    }
}
