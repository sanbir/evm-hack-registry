// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    SpinLottery,
    SpinLotteryFixed,
    PrizeNFT,
    MarkerToken
} from "./62544-h-07-spinlottery-will-break-if-the-first-prizeid-is-selected.sol";

contract SpinLotteryFirstPrizeStrandTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant WINNER1 = 0x0000000000000000000000000000000000000a01;
    address internal constant WINNER2 = 0x0000000000000000000000000000000000000a02;

    uint8 internal constant RARITY = 1;
    uint88 internal constant TOKEN_A = 100;
    uint88 internal constant TOKEN_B = 200;

    function test_exploit_firstPrizeSelected_strandsSurvivor() public {
        Exploit e = new Exploit();
        e.run();

        // 2 prizes seeded, but a single claim collapses the window to 0 (not 1).
        assertEq(e.claimableBefore(), 2, "two prizes seeded");
        assertEq(e.claimableAfterBuggy(), 0, "window collapsed 2 -> 0 after one claim");

        // firstPrizeId++ AND nextPrizeId-- both ran -> both pointers landed on 2.
        assertEq(e.firstPrizeIdAfter(), 2, "firstPrizeId incorrectly incremented");
        assertEq(e.nextPrizeIdAfter(), 2, "nextPrizeId decremented");

        // The survivor's record is still valid (moved into slot 1) yet unreachable.
        assertTrue(e.strandedPrizeData() != 0, "survivor prize record remains, but stranded");

        // The next spin reverts NoPrizesAvailable -> the survivor can never be claimed.
        assertTrue(e.secondSpinReverted(), "second spin reverts NoPrizesAvailable");

        // Exactly one prize NFT is permanently locked in the lottery contract.
        assertEq(e.lockedNftCount(), 1, "exactly one NFT stranded");
        PrizeNFT nft = PrizeNFT(e.nftAddr());
        assertEq(nft.ownerOf(TOKEN_A), WINNER1, "first prize delivered to winner1");
        assertEq(nft.ownerOf(TOKEN_B), e.lotteryAddr(), "survivor NFT locked in lottery forever");

        // Marker records the harmed magnitude at the SINK.
        MarkerToken marker = MarkerToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), 1, "1 locked prize recorded at SINK");
    }

    function test_control_fixedVariant_claimsBothPrizes() public {
        // Rebuild the identical scenario against the FIXED contract.
        PrizeNFT nft = new PrizeNFT();
        SpinLotteryFixed lottery = new SpinLotteryFixed();

        nft.mint(address(lottery), TOKEN_A);
        nft.mint(address(lottery), TOKEN_B);

        lottery.seedPrize(RARITY, 1, address(nft), TOKEN_A);
        lottery.seedPrize(RARITY, 2, address(nft), TOKEN_B);
        lottery.setPointers(RARITY, 1, 3);

        assertEq(lottery.claimableCount(RARITY), 2, "two prizes seeded");

        // First spin hits the first prize (same seed that breaks the buggy path).
        lottery.spinAndClaim(RARITY, 0, WINNER1);

        // Window shrinks by exactly 1: the moved survivor is still claimable.
        assertEq(lottery.claimableCount(RARITY), 1, "fixed: window 2 -> 1 (survivor stays claimable)");

        // Second spin succeeds and delivers the survivor NFT.
        lottery.spinAndClaim(RARITY, 0, WINNER2);
        assertEq(lottery.claimableCount(RARITY), 0, "fixed: both prizes drained");

        // Both NFTs delivered to winners; nothing locked in the lottery.
        assertEq(nft.ownerOf(TOKEN_A), WINNER1, "first prize delivered");
        assertEq(nft.ownerOf(TOKEN_B), WINNER2, "survivor prize delivered (not stranded)");
        assertTrue(
            nft.ownerOf(TOKEN_A) != address(lottery) && nft.ownerOf(TOKEN_B) != address(lottery),
            "fixed: no prize NFT stranded in the lottery"
        );
    }
}
