// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    WETH,
    VaultETHFixed
} from "./37229-reentrancy-attack-is-possible-on-selleth-function-zokyo-none.sol";

contract FixedHook {
    VaultETHFixed public vault;
    bool internal entered;

    constructor(VaultETHFixed vault_) {
        vault = vault_;
    }

    function onETH(uint256) external {
        if (entered) return;
        entered = true;
        try vault.SellETH(1 ether) {} catch {}
    }

    function sell() external {
        vault.SellETH(1 ether);
    }
}

contract Finding37229Test is Test {
    function test_exploit_reenters_sell_and_takes_victim_weth() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.received(), 2 ether, "risk manager received 2 WETH");
        assertEq(e.weth().balanceOf(address(e.vault())), 0, "vault empty");
        assertEq(e.vault().shares(e.victim()), 1 ether, "victim shares still 1");
        assertEq(e.received() - 1 ether, 1 ether, "1 WETH stolen");
    }

    function test_control_clear_shares_before_send_pays_one() public {
        WETH weth = new WETH();
        VaultETHFixed vault = new VaultETHFixed(weth);
        FixedHook hook = new FixedHook(vault);
        vault.setRisk(address(hook));
        weth.mint(address(vault), 2 ether);
        vault.credit(address(0xCAFE), 1 ether);
        vault.credit(address(hook), 1 ether);
        hook.sell();
        assertEq(weth.balanceOf(address(hook)), 1 ether, "only the caller's share");
        assertEq(weth.balanceOf(address(vault)), 1 ether, "victim WETH stays");
        assertEq(vault.shares(address(0xCAFE)), 1 ether, "victim shares");
        assertEq(vault.shares(address(hook)), 0, "caller shares cleared");
    }
}
