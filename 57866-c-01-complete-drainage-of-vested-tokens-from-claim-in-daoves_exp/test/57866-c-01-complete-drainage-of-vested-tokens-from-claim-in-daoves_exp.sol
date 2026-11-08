// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, DaoToken} from "./57866-c-01-complete-drainage-of-vested-tokens-from-claim-in-daoves.sol";

/// Claim is only accepted from a registered DaosLive, and the amount is the
/// stored contribution of that user, never a balance reported by the caller.
contract DaosVestingFixed {
    error NotDao();
    error UnknownDao();

    DaoToken public token;
    mapping(address => bool) public legitimate;
    mapping(address => mapping(address => uint256)) public contribution;

    constructor(address _token) {
        token = DaoToken(_token);
    }

    function register(address dao, address user, uint256 amount) external {
        legitimate[dao] = true;
        contribution[dao][user] = amount;
    }

    function claim(address dao, address user) external returns (uint256 amount) {
        if (msg.sender != dao) revert NotDao();
        if (!legitimate[dao]) revert UnknownDao();
        amount = contribution[dao][user];
        contribution[dao][user] = 0;
        if (amount > 0) token.transfer(user, amount);
    }
}

contract RealDao {
    function claimFor(DaosVestingFixed vesting, address user) external returns (uint256) {
        return vesting.claim(address(this), user);
    }
}

contract Finding57866Test is Test {
    function test_exploit_claim_drains_the_vesting_pot() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.attackerBalance(), e.POT(), "attacker received the full pot");
        assertEq(e.token().balanceOf(address(e)), e.POT(), "exploit holds the drained tokens");
        assertEq(e.contributorBalance(), 0, "contributor received nothing");
        assertEq(e.potLeft(), 0, "vesting pot is empty");
        assertEq(e.token().balanceOf(address(e.vesting())), 0, "vesting balance is 0");
    }

    function test_control_pays_only_the_callers_vested_amount() public {
        DaoToken token = new DaoToken();
        DaosVestingFixed vesting = new DaosVestingFixed(address(token));
        RealDao dao = new RealDao();
        address contributor = address(0xBEEF);
        address attacker = address(0xA11CE);

        token.mint(address(vesting), 1000e18);
        vesting.register(address(dao), contributor, 250e18);

        vm.prank(attacker);
        vm.expectRevert(DaosVestingFixed.NotDao.selector);
        vesting.claim(address(dao), attacker);

        vm.prank(attacker);
        vm.expectRevert(DaosVestingFixed.UnknownDao.selector);
        vesting.claim(attacker, attacker);

        uint256 paid = dao.claimFor(vesting, contributor);
        assertEq(paid, 250e18, "only the caller's vested amount");
        assertEq(token.balanceOf(contributor), 250e18, "contributor received 250");
        assertEq(token.balanceOf(attacker), 0, "attacker received nothing");
        assertEq(token.balanceOf(address(vesting)), 750e18, "the rest of the pot stays");
    }
}
