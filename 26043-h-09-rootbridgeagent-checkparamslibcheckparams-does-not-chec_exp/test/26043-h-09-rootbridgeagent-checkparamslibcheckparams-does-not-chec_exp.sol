// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./26043-h-09-rootbridgeagent-checkparamslibcheckparams-does-not-chec.sol";

contract MaiaCheckParamsMismatchTest is Test {
    Exploit exp;

    function setUp() public {
        exp = new Exploit();
    }

    function test_deposit_usdc_mint_hether() public {
        exp.run();
        emit log_named_uint("hEther minted", exp.attackerHEther());
        assertEq(exp.attackerHEther(), 10 ether, "minted 10 hEther");
        assertEq(exp.usdcSpent(), 10 ether, "spent 10 USDC");
    }
}
