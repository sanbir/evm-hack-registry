// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, CLGauge, MockKitten, MockNFP} from "./58151-c-02-clgauge-sends-kitten-rewards-to-itself-instead-of-to-st.sol";

// KittenSwap C-02 (finding 58151): CLGauge._getReward derives the reward
// recipient from nfp.ownerOf(nfpTokenId), which after staking is the gauge
// itself. The verbatim code self-transfers the KITTEN reward from the gauge to
// the gauge; the staker receives nothing and 100% of rewards are stranded.
contract Finding58151Test is Test {
    function test_exploit_clgaugeSendsRewardToItself_strandsStakerRewards() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("staker received", e.stakerReceived());
        emit log_named_uint("stranded in gauge", e.strandedInGauge());
        emit log_named_uint("loss (marked to sink)", e.lost());

        assertEq(e.stakerReceived(), 0, "staker must receive nothing");
        assertEq(e.strandedInGauge(), 1000 ether, "reward stranded in the gauge");
        assertEq(e.kitten().balanceOf(address(0x000000000000000000000000000000000000D00d)), 1000 ether, "loss marked to sink");
    }
}
