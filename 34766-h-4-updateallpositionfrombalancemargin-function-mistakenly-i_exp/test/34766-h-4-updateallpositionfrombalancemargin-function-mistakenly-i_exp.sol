// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    USDC,
    PositionMarginProcess
} from "./34766-h-4-updateallpositionfrombalancemargin-function-mistakenly-i.sol";

contract PositionMarginFixed is PositionMarginProcess {
    constructor(address _usdc) PositionMarginProcess(_usdc) {}

    function updateAllPositionFromBalanceMargin(int256 amount, bytes32 originPositionKey) external override {
        if (amount == 0) return;
        int256 reduceAmount = amount;
        for (uint256 i; i < keys.length; i++) {
            bytes32 key = keys[i];
            Position storage position = positions[key];
            if (marginToken == position.marginToken && position.isCrossMargin) {
                bool isOrigin = originPositionKey.length > 0 && originPositionKey == position.key;
                int256 budget = reduceAmount;
                uint256 changeAmount = _setFromRemaining(key, isOrigin, budget);
                reduceAmount = amount > 0 ? reduceAmount - int256(changeAmount) : reduceAmount + int256(changeAmount);
                if (reduceAmount == 0) break;
            }
        }
    }

    function _setFromRemaining(bytes32 key, bool isOrigin, int256 budget) internal returns (uint256 changeAmount) {
        if (isOrigin || budget <= 0) return 0;
        Position storage position = positions[key];
        uint256 borrowMargin = (position.initialMarginInUsd - position.initialMarginInUsdFromBalance)
            * position.initialMargin / position.initialMarginInUsd;
        uint256 budgetUint = uint256(budget);
        changeAmount = budgetUint < borrowMargin ? budgetUint : borrowMargin;
        position.initialMarginInUsdFromBalance =
            changeAmount * position.initialMarginInUsd / position.initialMargin;
    }
}

contract Finding34766Test is Test {
    function test_exploit_sol_from_balance_is_double_and_extra_margin_is_pulled() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.ethSize(), 500e18, "ETH from-balance 500");
        assertEq(e.solSize(), 1000e18, "SOL from-balance 1000");
        assertEq(e.fairSol(), 500e18, "fair SOL is 500");
        assertEq(e.solSize(), e.fairSol() * 2, "SOL is 2x");
        assertEq(e.extraMargin(), 500e18, "extra margin 500");
        assertEq(e.extraBorrow(), 2500e18, "extra 5x borrow 2500");
        assertEq(e.withdrawn(), 1500e18, "pulled 1500");
        assertEq(e.fairWithdraw(), 1000e18, "fair pull is 1000");
        emit log_named_uint("SOL size", e.solSize());
        emit log_named_uint("fair SOL", e.fairSol());
        emit log_named_uint("extra margin", e.extraMargin());
        emit log_named_uint("withdrawn", e.withdrawn());
    }

    function test_control_sets_sol_from_balance_to_the_remainder() public {
        USDC usdc = new USDC();
        PositionMarginFixed book = new PositionMarginFixed(address(usdc));
        usdc.mint(address(book), 1500e18);
        book.addPosition(bytes32(uint256(1)), 500e18, 500e18);
        book.addPosition(bytes32(uint256(2)), 1000e18, 1000e18);

        book.updateAllPositionFromBalanceMargin(int256(1000e18), bytes32(uint256(3)));

        (,,,,, uint256 ethSize) = book.positions(bytes32(uint256(1)));
        (,,,,, uint256 solSize) = book.positions(bytes32(uint256(2)));
        assertEq(ethSize, 500e18, "control ETH set to 500");
        assertEq(solSize, 500e18, "control SOL set to 500");

        uint256 paid = book.pullCreditedMargin(address(this));
        assertEq(paid, 1000e18, "control pays the 1000 settlement and no extra");
        assertEq(usdc.balanceOf(address(book)), 500e18, "LP liquidity stays");
        emit log_named_uint("control SOL", solSize);
        emit log_named_uint("control paid", paid);
    }
}
