// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, ERC721DAO, FactoryGuarded, GuardedBuyer} from
    "./41385-h-01-bypassing-maxtokensperuser-limits-for-erc721-dao-pashov.sol";

contract Finding41385Test is Test {
    function test_exploit_reenter_mints_20_when_max_is_15() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.dao().balanceOf(address(e)), 20, "20 nfts");
        assertEq(e.dao().maxTokensPerUser(), 15, "max 15");
        assertGt(e.dao().balanceOf(address(e)), e.dao().maxTokensPerUser(), "over cap");
    }

    function test_control_reentrancy_guard_stops_at_10() public {
        ERC721DAO dao = new ERC721DAO();
        FactoryGuarded factory = new FactoryGuarded(dao);
        dao.setFactory(address(factory));
        dao.setDetails(15, false);
        factory.setDistribution(100);
        GuardedBuyer buyer = new GuardedBuyer(factory);
        buyer.buy();

        assertEq(dao.balanceOf(address(buyer)), 10, "guard holds the cap");
        assertLe(dao.balanceOf(address(buyer)), dao.maxTokensPerUser(), "under max");
    }
}
