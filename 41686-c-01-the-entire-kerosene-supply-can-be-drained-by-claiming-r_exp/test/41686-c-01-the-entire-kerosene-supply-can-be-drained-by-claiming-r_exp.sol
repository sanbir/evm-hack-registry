// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {
    Exploit,
    Kerosene,
    Notes,
    DyadXP,
    Holder
} from "./41686-c-01-the-entire-kerosene-supply-can-be-drained-by-claiming-r.sol";

/// Recommended scale: divide by 1e18 after the same product.
contract FixedStaking {
    function claim(Kerosene token, Holder holder, address to, uint256 supply) external {
        uint256 timeDiff = 1;
        uint256 rewardsRate = 1;
        uint256 liquidity = 1;
        uint256 xp = supply;
        uint256 rewards = timeDiff * rewardsRate * liquidity * xp / 1e18;
        holder.approve(token, address(this), rewards);
        token.transferFrom(address(holder), to, rewards);
    }
}

contract Finding41686Test is Test {
    function test_exploit_one_wei_stake_takes_the_kerosene_supply() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.preview(), e.SUPPLY(), "preview");
        assertEq(e.profit(), e.SUPPLY(), "claimed");
        assertEq(e.holderLeft(), 0, "holder");
        assertEq(e.kerosene().balanceOf(address(e.holder())), 0, "still funded");

        console.log("liquidity wei", uint256(1));
        console.log("seconds staked", uint256(1));
        console.log("rewardsRate", uint256(1));
        console.log("kerosene claimed", e.profit());
        console.log("holder left", e.holderLeft());
    }

    function test_control_divide_by_1e18_leaves_almost_all_kerosene() public {
        uint256 supply = 1_000_000_000 ether;
        Kerosene token = new Kerosene();
        Holder holder = new Holder();
        token.mint(address(holder), supply);

        FixedStaking fixedStaking = new FixedStaking();
        fixedStaking.claim(token, holder, address(this), supply);

        assertEq(token.balanceOf(address(this)), 1e9, "scaled claim");
        assertEq(token.balanceOf(address(holder)), supply - 1e9, "not drained");
        console.log("control claimed", token.balanceOf(address(this)));
        console.log("control holder left", token.balanceOf(address(holder)));
    }
}
