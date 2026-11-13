// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, PoolToken, UpliftHookFixed} from
    "./49678-fee-evasion-via-lp-token-transfer-resets-deposit-value-codeh.sol";

contract Finding49678Test is Test {
    function test_exploit_transfer_resets_uplift_fee() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.fair(), 820 ether, "fair");
        assertEq(e.paid(), 999.5 ether, "paid");
        assertEq(e.token().balanceOf(address(e.alice())), 999.5 ether, "alice");
    }

    function test_control_transfer_keeps_original_deposit_value() public {
        PoolToken token = new PoolToken();
        UpliftHookFixed hook = new UpliftHookFixed(token);
        token.mint(address(hook), 1000 ether);
        hook.setFee(address(this), 1, 100 ether);
        hook.afterUpdate(address(this), address(0xA11CE), 1);
        uint256 out = hook.removeLiquidity(address(0xA11CE));
        assertEq(out, 820 ether, "uplift fee still due");
        assertEq(token.balanceOf(address(0xA11CE)), 820 ether, "paid fair");
    }
}
