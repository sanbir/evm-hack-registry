// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    Usdc,
    ModuleBase,
    CredibleAccountModule,
    CredibleAccountModuleFixed,
    Wallet
} from "./61405-c-03-wrong-wallet-validation-in-disablesessionkey-when-calle.sol";

contract Finding61405Test is Test {
    function test_exploit_disabler_clears_victim_lock() public {
        Exploit e = new Exploit();
        uint256 beforeBal = e.token().balanceOf(address(this));
        e.run();

        assertEq(e.token().balanceOf(address(this)) - beforeBal, 1_000e18, "disabler received 1000");
        assertEq(e.wallet().spent(), 1_000e18, "spend N");
        assertEq(e.module().lockedOf(address(e.wallet())), 0, "lock gone");
        assertEq(e.module().disabledFor(), address(e.wallet()), "someone else's wallet");
        assertEq(e.module().checkedWallet(), address(e), "checked the disabler");
        assertEq(e.module().checkedUntil(), 0, "disabler validUntil is 0");
        assertEq(e.token().balanceOf(address(e.wallet())), 0, "wallet paid the 1000");
    }

    function test_control_checks_target_wallet() public {
        Usdc token = new Usdc();
        CredibleAccountModuleFixed fixedModule = new CredibleAccountModuleFixed();
        Wallet wallet = new Wallet(token, ModuleBase(address(fixedModule)));
        token.mint(address(wallet), 1_000e18);
        wallet.enable(fixedModule.SESSION(), 1, type(uint48).max, fixedModule.LOCKED());
        assertEq(fixedModule.lockedOf(address(wallet)), 1_000e18, "still locked");

        try fixedModule.disableSessionKey(fixedModule.SESSION()) {
            fail();
        } catch (bytes memory err) {
            assertGt(err.length, 0, "control reverted on the victim wallet");
        }

        (, , uint48 until, bool live) = fixedModule.sessionData(fixedModule.SESSION(), address(wallet));
        assertEq(until, type(uint48).max, "victim validUntil still live");
        assertTrue(live, "session still live");
        assertEq(fixedModule.disabledFor(), address(0), "key not removed");
        assertEq(fixedModule.lockedOf(address(wallet)), 1_000e18, "1000 stays locked");

        try wallet.spend(address(this), 1_000e18) {
            fail();
        } catch {}

        assertEq(wallet.spent(), 0, "key cannot spend");
        assertEq(token.balanceOf(address(wallet)), 1_000e18, "1000 unspent");
        assertEq(token.balanceOf(address(this)), 0, "caller received nothing");
    }
}
