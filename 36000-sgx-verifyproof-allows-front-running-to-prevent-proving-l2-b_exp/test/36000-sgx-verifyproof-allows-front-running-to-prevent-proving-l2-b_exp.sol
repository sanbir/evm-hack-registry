// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, Reward, SgxVerifier, TaikoL1} from "./36000-sgx-verifyproof-allows-front-running-to-prevent-proving-l2-b.sol";

contract Finding36000Test is Test {
    function test_exploit_front_run_blocks_the_prover() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.instanceAfter(), e.NEW_INSTANCE(), "instance rotated");
        assertTrue(e.proved() == false, "block was not proved");
        assertEq(e.proverPaid(), 0, "prover was paid nothing");
        assertEq(e.rewardLeft(), 5 ether, "5 TKO stays in TaikoL1");
    }

    function test_control_prove_pays_the_prover() public {
        Reward reward = new Reward();
        SgxVerifier verifier = new SgxVerifier(0x70997970C51812dc3A010C7d01b50e0d17dc79C8);
        TaikoL1 taiko = new TaikoL1(verifier, reward);
        reward.mint(address(taiko), 5 ether);
        taiko.proveBlock(
            1,
            0x5555555555555555555555555555555555555555,
            27,
            0x221ba1e501f28021b838e56f616b339623d0917d77f35015d362577bdc555e45,
            0x6a1648d3bdf97395ff91cc16aaa07e1909f7ae7dacf31d428eddb4f71d4cbb04,
            address(0x2222)
        );
        assertTrue(taiko.proved(1), "proved");
        assertEq(reward.balanceOf(address(0x2222)), 5 ether, "prover received 5 TKO");
        assertEq(reward.balanceOf(address(taiko)), 0, "TaikoL1 paid the reward");
    }
}
