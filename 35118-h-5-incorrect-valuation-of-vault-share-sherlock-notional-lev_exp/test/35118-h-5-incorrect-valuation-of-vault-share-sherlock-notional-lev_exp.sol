// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    WithdrawRequestBase,
    TradingModule,
    MiniToken,
    WithdrawRequest,
    SplitWithdrawRequest
} from "./35118-h-5-incorrect-valuation-of-vault-share-sherlock-notional-lev.sol";

contract FixedValuation {
    uint256 public constant EXCHANGE_RATE_PRECISION = 1e18;
    uint256 public constant BORROW_PRECISION = 1e6;
    uint256 public constant REDEMPTION_PRECISION = 1e18;
    TradingModule public trading;

    constructor(TradingModule trading_) {
        trading = trading_;
    }

    function value(WithdrawRequest memory w, SplitWithdrawRequest memory s) external view returns (uint256) {
        (int256 rate,) = trading.getOraclePrice(address(0), address(0));
        return (s.totalWithdraw * uint256(rate) * w.vaultShares * BORROW_PRECISION) /
            (s.totalVaultShares * EXCHANGE_RATE_PRECISION * REDEMPTION_PRECISION);
    }
}

contract Finding35118Test is Test {
    function test_exploit_share_value_overborrows() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.buggy(), 500000000000000000000, "buggy borrow");
        assertEq(e.fair(), 500000000, "fair borrow");
        assertEq(e.borrowed(), e.buggy(), "vault paid the buggy amount");
        assertEq(e.usdc().balanceOf(address(e)), 500000000000000000000, "attacker balance");
        assertEq(e.buggy() / e.fair(), 1e12, "inflation");
    }

    function test_control_borrow_precision_matches_fair_share() public {
        Exploit e = new Exploit();
        WithdrawRequest memory w = WithdrawRequest({vaultShares: 5e8});
        SplitWithdrawRequest memory s = SplitWithdrawRequest({totalWithdraw: 100 ether, totalVaultShares: 10e8});

        FixedValuation fixedValue = new FixedValuation(e.trading());
        assertEq(fixedValue.value(w, s), 500000000, "control share price");
        assertEq(e.vault().fairValue(w, s), 500000000, "fair helper");
        assertEq(e.vault().quote(w, s), 500000000000000000000, "buggy quote");

        e.run();
        assertGt(e.borrowed(), fixedValue.value(w, s), "buggy borrow is not above the fair share");
        assertEq(e.borrowed() - fixedValue.value(w, s), 500000000000000000000 - 500000000, "excess");
    }
}
