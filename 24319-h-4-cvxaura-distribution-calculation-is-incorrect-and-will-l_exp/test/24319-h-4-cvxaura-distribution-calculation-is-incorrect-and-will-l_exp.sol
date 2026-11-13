// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, Aura, AuraPools, WAuraPools} from "./24319-h-4-cvxaura-distribution-calculation-is-incorrect-and-will-l.sol";

/// Control: cache aura-per-BAL at the moment the minter actually mints.
contract WAuraPoolsFixed is WAuraPools {
    uint256 public perBal;

    constructor(Aura aura_, AuraPools pools_) WAuraPools(aura_, pools_) {}

    function withdraw(address user) external override returns (uint256 paid) {
        uint256 userBal = user == userA ? balA : balB;
        require(userBal > 0, "user");
        if (!claimed) {
            uint256 quote = _minterQuote(balA + balB);
            AURA.mint(address(this), quote);
            totalMinted = quote;
            perBal = (quote * 1e18) / (balA + balB);
            claimed = true;
        }
        paid = (userBal * perBal) / 1e18;
        require(AURA.transfer(user, paid), "pay");
        if (user == userA) paidA = paid;
        else paidB = paid;
    }
}

contract Finding24319Test is Test {
    function test_exploit_post_claim_cliff_underpays_both_lps() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.wrapper().totalMinted(), 3900, "minter used cliff 0");
        assertEq(e.wrapper().paidA(), 975, "A lost 975");
        assertEq(e.wrapper().paidB(), 975, "B lost 975");
        assertEq(e.aura().balanceOf(address(e.wrapper())), 1950, "1950 stuck");
        assertEq(e.aura().balanceOf(e.userA()) + e.aura().balanceOf(e.userB()), 1950, "users got half");
    }

    function test_control_cached_rate_pays_the_minted_aura() public {
        Aura aura = new Aura();
        AuraPools pools = new AuraPools();
        WAuraPoolsFixed wrapper = new WAuraPoolsFixed(aura, pools);
        address a = address(0xA11CE);
        address b = address(0xB0B);
        wrapper.setUsers(a, b, 500, 500);
        wrapper.withdraw(a);
        wrapper.withdraw(b);
        assertEq(wrapper.paidA(), 1950, "A fair share");
        assertEq(wrapper.paidB(), 1950, "B fair share");
        assertEq(aura.balanceOf(address(wrapper)), 0, "nothing stuck");
        assertEq(aura.balanceOf(a), 1950, "A balance");
        assertEq(aura.balanceOf(b), 1950, "B balance");
    }
}
