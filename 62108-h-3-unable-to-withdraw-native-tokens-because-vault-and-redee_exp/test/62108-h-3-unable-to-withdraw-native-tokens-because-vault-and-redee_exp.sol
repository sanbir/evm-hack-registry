// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./62108-h-3-unable-to-withdraw-native-tokens-because-vault-and-redee.sol";

contract Mellow62108Test is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        vm.deal(address(e), 1 ether);
        e.run();
        assertTrue(e.getLiquidAssetsReverted(), "liquid query reverts");
        assertTrue(e.processWithdrawReverted(), "withdraw reverts");
        assertEq(e.ethStuck(), 1 ether, "1 ETH stuck");
    }
}
