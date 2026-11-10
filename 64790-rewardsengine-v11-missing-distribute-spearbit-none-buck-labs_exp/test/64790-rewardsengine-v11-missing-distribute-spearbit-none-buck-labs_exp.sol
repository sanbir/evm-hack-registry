// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {
    Exploit,
    RewardToken,
    RewardsEngineV1,
    RewardsProxy
} from "./64790-rewardsengine-v11-missing-distribute-spearbit-none-buck-labs.sol";

contract Finding64790Test is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    function test_v11_leaves_coupon_stuck_and_claim_returns_zero() public {
        Exploit e = new Exploit();
        vm.prank(ATTACKER);
        e.run();

        assertEq(e.claimed(), 0, "claim is 0");
        assertEq(e.stuck(), 1000 ether, "N stuck");
        assertEq(e.token().balanceOf(address(e.proxy())), 1000 ether, "proxy balance");
        assertEq(e.token().balanceOf(ATTACKER), 0, "user received nothing");
        assertEq(RewardsEngineV1(address(e.proxy())).pending(), 1000 ether, "pending uncleared");
        assertEq(RewardsEngineV1(address(e.proxy())).claimable(ATTACKER), 0, "claimable");

        console2.log("claimed", e.claimed());
        console2.log("stuck", e.stuck());
        console2.log("user", e.token().balanceOf(ATTACKER));
    }

    function test_control_v1_distributes_and_user_receives_n() public {
        RewardToken token = new RewardToken();
        RewardsEngineV1 v1 = new RewardsEngineV1();
        RewardsProxy proxy = new RewardsProxy();
        proxy.upgradeTo(address(v1));

        token.mint(address(this), 1000 ether);
        token.approve(address(proxy), 1000 ether);
        RewardsEngineV1(address(proxy)).initialize(token, ATTACKER);
        RewardsEngineV1(address(proxy)).fund(1000 ether);
        RewardsEngineV1(address(proxy)).distribute(1000 ether);

        vm.prank(ATTACKER);
        uint256 got = RewardsEngineV1(address(proxy)).claim();

        assertEq(got, 1000 ether, "user receives N");
        assertEq(token.balanceOf(ATTACKER), 1000 ether, "balance");
        assertEq(token.balanceOf(address(proxy)), 0, "proxy emptied");
        assertEq(RewardsEngineV1(address(proxy)).pending(), 0, "pending cleared");
        assertEq(RewardsEngineV1(address(proxy)).claimable(ATTACKER), 0, "claimable spent");

        console2.log("control received", got);
        console2.log("control proxy left", token.balanceOf(address(proxy)));
    }
}
