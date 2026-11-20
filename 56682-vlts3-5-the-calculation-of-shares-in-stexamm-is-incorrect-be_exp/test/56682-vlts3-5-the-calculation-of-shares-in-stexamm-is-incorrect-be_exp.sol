// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, AMMFixed} from
    "./56682-vlts3-5-the-calculation-of-shares-in-stexamm-is-incorrect-be.sol";

contract Finding56682Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_stale_pending_mints_27() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.amm().lastShares(), 27 ether, "27 shares");
        assertEq(e.marker().balanceOf(SINK), 9 ether, "9 extra");
    }

    function test_control_updated_pending_mints_18() public {
        AMMFixed amm = new AMMFixed();
        uint256 minted = amm.deposit(address(this), 18 ether);
        assertEq(minted, 18 ether, "18 shares");
        assertEq(amm.sharesOf(address(this)), 18 ether, "credited 18");
    }
}
