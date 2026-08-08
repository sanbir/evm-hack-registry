// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    RebaseToken,
    CryptoLegacyVestingFixed,
    IRebaseToken,
    IClaimable
} from "./61287-rebaseable-tokens-cause-unfair-vesting-and-claim-failures-.sol";

contract PoC61287 is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_rebase_unfair_vesting() public {
        Exploit e = new Exploit();
        e.run();

        // Two beneficiaries held EQUAL 50% shares, yet ended with unequal totals.
        assertEq(e.aFinal(), 1125e18, "A should end with 1125 tokens");
        assertEq(e.bFinal(), 875e18, "B should end with 875 tokens");

        // Concrete unfairness: 250-token gap between equal-share beneficiaries.
        assertEq(e.disparity(), 250e18, "unfair disparity should be 250 tokens");
        assertGt(e.aFinal(), e.bFinal(), "equal shares yielded unequal payouts");

        // Marker records the harm magnitude to SINK.
        assertEq(e.marker().balanceOf(SINK), 250e18, "marker must equal the disparity");
    }

    function test_control_fixed_shares_are_fair() public {
        // Same token, same 1000-token pool, same 50/50 shares, same rebase timing,
        // but the FIXED (share-invariant) accounting distributes fairly.
        address A = address(0xA11CE);
        address B = address(0xB0B);

        RebaseToken token = new RebaseToken();
        CryptoLegacyVestingFixed fv = new CryptoLegacyVestingFixed(IRebaseToken(address(token)));

        token.mint(address(fv), 1000e18);
        fv.setShare(A, 5000);
        fv.setShare(B, 5000);
        fv.setVesting(A, 5000); // A 50% vested initially

        // 1. A claims early.
        vm.prank(A);
        fv.claim(address(token));

        // 2. same positive rebase x2.
        token.rebase(2e18);

        // 3. both fully vested.
        fv.setVesting(A, 10000);
        fv.setVesting(B, 10000);

        // 4. B claims, 5. A claims remainder.
        vm.prank(B);
        fv.claim(address(token));
        vm.prank(A);
        fv.claim(address(token));

        uint256 aFinal = token.balanceOf(A);
        uint256 bFinal = token.balanceOf(B);

        // SAFE: equal shares -> equal holdings, no disparity.
        assertEq(aFinal, bFinal, "fixed accounting must be fair");
        assertEq(aFinal, 1000e18, "A gets its fair 1000 tokens");
        assertEq(bFinal, 1000e18, "B gets its fair 1000 tokens");
    }
}
