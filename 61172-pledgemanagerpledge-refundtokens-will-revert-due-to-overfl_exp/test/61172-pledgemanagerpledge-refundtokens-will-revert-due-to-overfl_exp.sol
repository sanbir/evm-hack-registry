// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    MiniToken,
    PledgeManager,
    PledgeManagerFixed
} from "./61172-pledgemanagerpledge-refundtokens-will-revert-due-to-overfl.sol";

contract PledgeOverflowTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_reasonablePledgeRevertsDueToUint32Overflow() public {
        Exploit e = new Exploit();
        e.run();

        // The honest pledge ($1 x 5000 = $5000, i.e. 5e9 stablecoin units) reverts.
        assertTrue(e.pledgeReverted(), "pledge should revert on uint32*uint32 overflow");

        // Intended cost widened correctly = 5_000_000_000 (5e9), far below what the
        // uint32 product can represent (max 4_294_967_295), so it overflows and DoSes.
        assertEq(e.intendedStablecoinAmount(), 5_000_000_000, "intended amount");

        // Harm magnitude recorded on the marker token at SINK.
        assertEq(e.markerMinted(), 5_000_000_000, "marker mint amount");

        // Locate the marker token: 3rd `new` in run() -> Exploit nonce 3.
        MiniToken marker = MiniToken(computeCreateAddress(address(e), 3));
        assertEq(marker.balanceOf(SINK), 5_000_000_000, "marker balance at SINK == denied pledge value");
    }

    function test_control_fixedVariantAcceptsSamePledge() public {
        MiniToken stablecoin = new MiniToken("USDC");
        PledgeManagerFixed manager = new PledgeManagerFixed(stablecoin);

        address user = address(0x1111111111111111111111111111111111111111);
        uint32 pricePerToken = 1_000_000; // $1
        uint32 numTokens = 5000;
        uint256 intended = uint256(pricePerToken) * uint256(numTokens); // 5e9

        stablecoin.mint(user, intended);

        // Same inputs that DoS the vulnerable contract now succeed.
        vm.prank(user);
        uint256 charged = manager.pledge(user, pricePerToken, numTokens);

        assertEq(charged, 5_000_000_000, "fixed variant charges correct amount");
        assertEq(manager.pledgedOf(user), 5_000_000_000, "pledge recorded correctly");
        assertEq(stablecoin.balanceOf(address(manager)), 5_000_000_000, "stablecoin received");
    }
}
