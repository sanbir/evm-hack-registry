// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, StPlumeMinter, FixedMinter, EthToken} from
    "./57713-h-01-incorrect-accounting-of-currentwithheldethininstantwith.sol";

contract Finding57713Test is Test {
    function test_exploit_overpays_and_keeps_withheld() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.minter().currentWithheldETH(), 1_000e18, "withheld unchanged");
        assertEq(e.minter().paid(), 1_000e18, "paid 1000");
        assertEq(e.minter().fairPayout(), 900e18, "fair 900");
        assertEq(e.minter().paid() - e.minter().fairPayout(), 100e18, "overpaid 100");
        assertEq(e.ethToken().balanceOf(address(this)), 1_000e18, "alice received 1000");
        assertEq(e.minter().withHoldEth(), 100e18, "fee recorded");
        assertEq(e.ethToken().balanceOf(address(e.minter())), 0, "fee not kept");
    }

    function test_control_pays_nine_hundred() public {
        EthToken token = new EthToken();
        FixedMinter fixedMinter = new FixedMinter(token);
        fixedMinter.fundWithheld(1_000e18);
        fixedMinter.withdraw(address(0xF1), 1_000e18);
        assertEq(fixedMinter.paid(), 900e18, "control pays 900");
        assertEq(fixedMinter.currentWithheldETH(), 0, "withheld cleared");
        assertEq(fixedMinter.withHoldEth(), 100e18, "fee kept");
        assertEq(token.balanceOf(address(0xF1)), 900e18, "user 900");
        assertEq(token.balanceOf(address(fixedMinter)), 100e18, "100 stays");
    }
}
