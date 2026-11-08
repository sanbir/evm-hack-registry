// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, GachaToken} from "./55404-c-01-unauthorized-access-to-burn-gotcha-token-pashov-audit-g.sol";

/// @dev Auditor fix: delete burnFrom, and pass msg.sender as `by`.
contract GachaTokenFixed {
    mapping(address => mapping(uint256 => uint256)) public balanceOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    error NotOwnerNorApproved();

    function mint(address to, uint256 id, uint256 amount) external {
        balanceOf[to][id] += amount;
    }

    function setApprovalForAll(address operator, bool ok) external {
        isApprovedForAll[msg.sender][operator] = ok;
    }

    function burn(address from, uint256 id, uint256 amount) external {
        _burn(msg.sender, from, id, amount);
    }

    function _burn(address by, address from, uint256 id, uint256 amount) internal {
        if (by != from && !isApprovedForAll[from][by]) revert NotOwnerNorApproved();
        balanceOf[from][id] -= amount;
    }
}

contract Finding55404Test is Test {
    address internal constant VICTIM = address(0xBEEF);
    address internal constant STRANGER = address(0xA11CE);

    function test_exploit_burns_holder_balance_to_zero() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.beforeMint(), 0, "started empty");
        assertEq(e.afterMint(), 100, "credited 100");
        assertEq(e.afterBurn(), 0, "balance is 0");
        assertEq(e.token().balanceOf(VICTIM, 1), 0, "holder id 1 is 0");
        assertEq(e.token().burned(), 100, "100 burned");
    }

    function test_control_burn_requires_the_owner() public {
        GachaTokenFixed fixedToken = new GachaTokenFixed();
        fixedToken.mint(VICTIM, 1, 100);

        vm.prank(STRANGER);
        vm.expectRevert(GachaTokenFixed.NotOwnerNorApproved.selector);
        fixedToken.burn(VICTIM, 1, 100);
        assertEq(fixedToken.balanceOf(VICTIM, 1), 100, "stranger burned nothing");

        vm.prank(VICTIM);
        fixedToken.burn(VICTIM, 1, 100);
        assertEq(fixedToken.balanceOf(VICTIM, 1), 0, "owner can burn their own");
    }
}
