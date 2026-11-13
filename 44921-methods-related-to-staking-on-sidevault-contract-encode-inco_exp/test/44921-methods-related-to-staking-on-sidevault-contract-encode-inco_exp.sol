// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    StakeToken,
    StakingVault,
    Messenger,
    SideVaultFixed
} from "./44921-methods-related-to-staking-on-sidevault-contract-encode-inco.sol";

contract Finding44921Test is Test {
    function test_exploit_wrong_selector_keeps_100_in_the_side_vault() public {
        Exploit e = new Exploit();
        e.run();

        assertFalse(e.relayed(), "relay reverted");
        assertEq(e.stayed(), 100 ether, "100 stayed");
        assertEq(e.credited(), 0, "staking credit is 0");
        assertEq(e.token().balanceOf(address(e.staking())), 0, "staking vault holds 0");
        assertEq(e.token().balanceOf(address(e.side())), 100 ether, "side vault holds 100");
    }

    function test_control_staking_selector_credits_100() public {
        StakeToken token = new StakeToken();
        StakingVault staking = new StakingVault(token);
        Messenger messenger = new Messenger();
        SideVaultFixed side = new SideVaultFixed(token, address(staking), messenger);
        staking.setSide(address(side));
        token.mint(address(this), 100 ether);
        token.approve(address(side), 100 ether);

        bool ok = side.stakingAccountDeposit(100 ether);

        assertTrue(ok, "relay succeeded");
        assertEq(staking.staked(address(this)), 100 ether, "user credited 100");
        assertEq(token.balanceOf(address(staking)), 100 ether, "staking vault holds 100");
        assertEq(token.balanceOf(address(side)), 0, "side vault forwarded the tokens");
    }
}
