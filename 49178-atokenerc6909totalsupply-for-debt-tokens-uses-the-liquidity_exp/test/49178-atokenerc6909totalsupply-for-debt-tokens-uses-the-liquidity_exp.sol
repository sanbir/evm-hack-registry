// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    ATokenERC6909Fixed,
    Collateral,
    Exploit,
    MarketFixed,
    Pool
} from "./49178-atokenerc6909totalsupply-for-debt-tokens-uses-the-liquidity.sol";

contract Finding49178Test is Test {
    function test_exploit_withdraw_uses_liquidity_index() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.aToken().totalSupply(1), 100 ether, "reported supply");
        assertEq(e.aToken().realDebt(1), 200 ether, "real debt");
        assertEq(e.market().paid(), 50 ether, "withdrew 50e18");
        assertEq(e.token().balanceOf(address(e)), 50 ether, "borrower");
        assertEq(e.token().balanceOf(address(e.market())), 100 ether, "collateral left");
        assertGt(e.aToken().realDebt(1), e.token().balanceOf(address(e.market())), "underwater");
    }

    function test_control_uses_real_debt_and_withdraw_reverts() public {
        Collateral token = new Collateral();
        Pool pool = new Pool();
        ATokenERC6909Fixed aToken = new ATokenERC6909Fixed(pool);
        MarketFixed market = new MarketFixed(token, aToken);
        token.mint(address(market), 150 ether);

        assertEq(aToken.totalSupply(1), 200 ether, "control reports real debt");

        bool paid;
        try market.withdraw(50 ether) {
            paid = true;
        } catch {
            paid = false;
        }

        assertFalse(paid, "withdraw reverted");
        assertEq(market.paid(), 0, "nothing paid");
        assertEq(token.balanceOf(address(market)), 150 ether, "collateral stays");
        assertEq(market.collateral(), 150 ether, "collateral accounting");
    }
}
