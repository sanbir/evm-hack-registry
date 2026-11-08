// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, DaosToken} from "./57869-h-02-in-finalize-the-minttodao-amount-of-tokens-are-permane.sol";

/// The recommended fix: mint the DAO allocation to the manager, not to the contract.
contract DaosLiveFixed {
    DaosToken public token;
    address public daoManager;

    constructor(address _token, address _manager) {
        token = DaosToken(_token);
        daoManager = _manager;
    }

    function finalize(uint256 mintToDao) external {
        if (mintToDao > 0) token.mint(daoManager, mintToDao);
    }
}

contract Finding57869Test is Test {
    function test_exploit_mintToDao_stuck_with_no_withdraw() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.stuck(), 1000e18, "1000 tokens sit on DaosLive");
        assertEq(e.token().balanceOf(address(e.dao())), 1000e18, "balanceOf(contract)");
        assertEq(e.managerBalance(), 0, "manager received nothing");
        assertEq(e.token().balanceOf(e.MANAGER()), 0, "manager balance stays 0");
        assertTrue(e.withdrawMissing(), "no withdraw");
    }

    function test_control_mints_the_allocation_to_the_dao_manager() public {
        DaosToken token = new DaosToken();
        address manager = address(0xBEEF);
        DaosLiveFixed fixedDao = new DaosLiveFixed(address(token), manager);

        fixedDao.finalize(1000e18);

        assertEq(token.balanceOf(address(fixedDao)), 0, "nothing stuck on the contract");
        assertEq(token.balanceOf(manager), 1000e18, "manager received the allocation");
    }
}
