// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, RECORD, FanToArtistStakingFixed} from "./59402-redeeming-does-not-discount-tokens-of-removed-artists-leadin.sol";

contract Finding59402Test is Test {
    address internal constant REMOVED = 0x2222222222222222222222222222222222222222;
    address internal constant ACTIVE = 0x3333333333333333333333333333333333333333;

    function test_exploit_removed_artist_mints_1000() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.removedMinted(), 1_000 ether, "removed artist minted half the pot");
        assertEq(e.record().balanceOf(REMOVED), 1_000 ether, "RECORD balance");
        assertEq(e.staking().artistStake(REMOVED), 1_000 ether, "stake not discounted");
    }

    function test_control_removed_artist_gets_nothing() public {
        RECORD record = new RECORD();
        FanToArtistStakingFixed s = new FanToArtistStakingFixed(record, REMOVED, ACTIVE);
        s.stakeFor(REMOVED, address(this), 1_000 ether);
        s.stakeFor(ACTIVE, address(this), 1_000 ether);
        s.removeArtist(REMOVED);
        s.redeem(REMOVED, address(this));
        assertEq(s.artistStake(REMOVED), 0, "discounted");
        s.getReward(REMOVED);
        s.getReward(ACTIVE);
        assertEq(record.balanceOf(REMOVED), 0, "no inflated mint");
        assertEq(record.balanceOf(ACTIVE), 2_000 ether, "active artist takes the pot");
    }
}
