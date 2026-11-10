// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    LpToken,
    PoolFixed
} from "./36353-h-13-incorrect-supply-update-when-adding-token-pashov-audit.sol";

contract Finding36353Test is Test {
    address internal constant USER = 0x2222222222222222222222222222222222222222;
    address internal constant GENESIS = 0x3333333333333333333333333333333333333333;

    function test_exploit_supply_and_deposit_shares_are_wrong() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.fairSupply() - e.wrongSupply(), e.SUPPLY_SHORTFALL(), "supply short by 4.187 LP");
        assertEq(e.priceGap(), e.PRICE_GAP(), "share price high by the gap");
        assertEq(e.lp().balanceOf(address(e)), e.ADDER_LP(), "adder was under-minted");
        assertEq(e.userShares(), e.USER_SHARES(), "depositor received 103.979 LP");
        assertEq(e.fairUserShares(), e.FAIR_USER_SHARES(), "fair deposit is 99.792 LP");
        assertEq(e.userShares() - e.fairUserShares(), e.SUPPLY_SHORTFALL(), "extra shares equal the supply shortfall");
        assertEq(e.lp().balanceOf(USER), e.userShares(), "user balance");
        assertEq(e.USER(), USER, "user address");
    }

    function test_control_new_amplification_mints_the_fair_shares() public {
        LpToken lp = new LpToken();
        PoolFixed pool = new PoolFixed(lp);
        pool.seed(100 ether, 50 ether, 150 ether, 200 ether, GENESIS);
        pool.addToken(25 ether, 3125 ether, address(this));

        assertEq(pool.supply(), 524598714666764808847, "supply uses amplification_");
        uint256 fairSupply = pool.supply();
        pool.deposit(0, 100 ether, USER);

        assertEq(lp.balanceOf(USER), 99792036462624242813, "depositor receives the fair LP");
        assertEq(lp.balanceOf(address(this)), 25791428207292335832, "adder receives the fair mint");
        assertEq(pool.supply() - fairSupply, 99792036462624242813, "deposit mint matches the user");
    }
}
