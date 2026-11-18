// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
import "forge-std/Test.sol";
import {Exploit, MockToken, Receiver, DepositUSD} from "./44978-c-01-wrong-token-transfer-in-executewithdrawal-pashov-audit.sol";

contract Finding44978Test is Test {
    function test_executeWithdrawal_locks_dai() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.withdrawalReverted(), "reverted");
        assertEq(e.daiLocked(), 1000 ether, "1000 DAI locked");
        assertEq(e.userDai(), 0, "user got no DAI");
        assertEq(address(e.vault()).balance, 0, "no ETH");
    }

    function test_control_fixed_sends_dai() public {
        MockToken dai = new MockToken("DAI");
        Receiver user = new Receiver();
        DepositUSD vault = new DepositUSD(dai, address(this));
        dai.mint(address(this), 1000 ether);
        dai.approve(address(vault), 1000 ether);
        bytes32 h = keccak256("nexus-withdrawal");
        vault.queueWithdrawal(address(user), h, 1000 ether);
        vault.executeWithdrawalFixed(address(user), h);
        assertEq(dai.balanceOf(address(user)), 1000 ether, "user received DAI");
        assertEq(dai.balanceOf(address(vault)), 0, "vault empty");
    }
}
