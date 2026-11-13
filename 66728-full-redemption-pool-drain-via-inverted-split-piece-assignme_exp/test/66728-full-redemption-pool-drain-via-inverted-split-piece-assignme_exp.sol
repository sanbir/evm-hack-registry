// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, ValueToken, YLD, RedemptionFixed} from
    "./66728-full-redemption-pool-drain-via-inverted-split-piece-assignme.sol";

contract Finding66728Test is Test {
    function test_exploit_withdraw_1_takes_the_remainder() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.received(), 2000, "received");
        assertEq(e.poolLeft(), 1, "pool");
        assertEq(e.lp1Share(), 0, "lp1");
        assertEq(e.value().balanceOf(address(e)), 2000, "balance");
    }

    function test_control_caller_receives_the_amt_slice() public {
        ValueToken value = new ValueToken();
        YLD yld = new YLD();
        RedemptionFixed fixedR = new RedemptionFixed(yld, value, 2000);
        value.mint(address(fixedR), 2000);
        value.mint(address(this), 1);
        uint256 id = yld.mint(address(this), 1);
        value.approve(address(fixedR), 1);
        fixedR.deposit(id);
        fixedR.withdraw(1);
        assertEq(value.balanceOf(address(this)), 1, "only the 1 unit");
        assertEq(yld.getNFTData(fixedR.NFTID()), 2000, "pool keeps remainder");
        assertEq(value.balanceOf(address(fixedR)), 2000, "value stays");
    }
}
