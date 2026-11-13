// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Mini, YTMinter, PoolFixed} from "./57093-race-condition-in-yt-swap-and-index-update-can-lead-to-loss.sol";

contract Finding57093Test is Test {
    function test_exploit_sticks_100_pt() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.poolIndexSeen(), 11e17, "pool index still 1.1");
        assertEq(e.minterIndexSeen(), 12e17, "minter index already 1.2");
        assertEq(e.quoted(), 1_100 ether, "pool booked 1100");
        assertEq(e.minted(), 1_200 ether, "minter minted 1200");
        assertEq(e.booked(), 1_100 ether, "totalSupplyPt is 1100");
        assertEq(e.stuck(), 100 ether, "100 PT stuck outside the book");
        assertEq(e.userYt(), 1_200 ether, "user received 1200 YT");
        assertEq(Mini(address(e.pt())).balanceOf(address(e.pool())), 1_200 ether, "pool holds 1200 PT");
    }

    function test_control_minter_uses_pool_index() public {
        Mini sy = new Mini("SY", "SY");
        Mini pt = new Mini("PT", "PT");
        Mini yt = new Mini("YT", "YT");
        YTMinter minter = new YTMinter(pt, yt);
        PoolFixed pool = new PoolFixed(sy, pt, minter);
        minter.setPool(address(pool));
        minter.setIndex(12e17);
        sy.mint(address(this), 1_000 ether);
        sy.approve(address(pool), 1_000 ether);

        uint256 quoted = pool.swapSyForYt(1_000 ether);
        uint256 stuck = pt.balanceOf(address(pool)) - pool.totalSupplyPt();

        assertEq(quoted, 1_100 ether, "quoted at the pool index");
        assertEq(pool.lastMinted(), 1_100 ether, "minter minted the pool's number");
        assertEq(stuck, 0, "nothing stuck");
        assertEq(yt.balanceOf(address(this)), 1_100 ether, "user YT matches the book");
    }
}
