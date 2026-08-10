// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    NFTManager,
    NFTManagerFixed,
    Decomposer,
    MiniToken,
    User
} from "./63170-h-4-uncollected-fees-from-users-nft-position-are-stuck-in-nf.sol";

contract UncollectedFeesStuckTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 internal constant POSITION_ID = 42;
    uint256 internal constant FEE = 100 ether;

    // ── Vulnerable path: decomposeAndMint strands the user's uncollected fees ──
    function test_exploit_uncollectedFeesStuckInNFTManager() public {
        Exploit e = new Exploit();
        e.run();

        // The user received NONE of their 100 + 100 uncollected fees.
        assertEq(e.userFee0After(), 0, "user should not have received fee0");
        assertEq(e.userFee1After(), 0, "user should not have received fee1");

        // The fees are stranded in NFTManager instead.
        assertEq(e.stuckFee0(), FEE, "fee0 stuck in NFTManager");
        assertEq(e.stuckFee1(), FEE, "fee1 stuck in NFTManager");

        // Prove it against the real token balances too.
        MiniToken t0 = MiniToken(e.token0Addr());
        MiniToken t1 = MiniToken(e.token1Addr());
        assertEq(t0.balanceOf(e.nftManagerAddr()), FEE, "NFTManager retains fee0");
        assertEq(t1.balanceOf(e.nftManagerAddr()), FEE, "NFTManager retains fee1");
        assertEq(t0.balanceOf(e.userAddr()), 0, "user holds no fee0");
        assertEq(t1.balanceOf(e.userAddr()), 0, "user holds no fee1");

        // The permanent loss magnitude is recorded on the marker at the SINK.
        assertEq(e.strandedFees(), 200 ether, "stranded magnitude = 200");
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), 200 ether, "marker records loss at SINK");
        assertEq(e.sinkMarkerBalance(), 200 ether, "sink marker balance");
    }

    // ── Negative control: the fixed manager forwards the residual to the user ──
    function test_control_fixedForwardsResidualToUser() public {
        MiniToken token0 = new MiniToken("Fee Token 0", "FEE0");
        MiniToken token1 = new MiniToken("Fee Token 1", "FEE1");
        Decomposer decomposer = new Decomposer();
        NFTManagerFixed nft = new NFTManagerFixed(address(decomposer));
        User user = new User();

        decomposer.setPositionFees(POSITION_ID, address(token0), address(token1), FEE, FEE);

        // Same call, but from the fixed manager (via the user as msg.sender).
        vm.prank(address(user));
        nft.decomposeAndMint(POSITION_ID, false, 0, 0, "");

        // The fix returns the swept fees to the user; nothing is stranded.
        assertEq(token0.balanceOf(address(user)), FEE, "user receives fee0");
        assertEq(token1.balanceOf(address(user)), FEE, "user receives fee1");
        assertEq(token0.balanceOf(address(nft)), 0, "no fee0 stuck");
        assertEq(token1.balanceOf(address(nft)), 0, "no fee1 stuck");
    }
}
