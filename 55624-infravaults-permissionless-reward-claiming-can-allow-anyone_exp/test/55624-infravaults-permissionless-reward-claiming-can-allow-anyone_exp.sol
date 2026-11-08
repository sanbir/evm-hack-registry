// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, Reward, InfraredVault} from "./55624-infravaults-permissionless-reward-claiming-can-allow-anyone.sol";

/// @dev Auditor fix: add the tokens already sitting on the vault to the amount forwarded.
contract MetaVaultFixed {
    InfraredVault public infra;
    Reward public token;
    address public owner;
    uint256 public forwarded;

    constructor(InfraredVault _infra, Reward _token, address _owner) {
        infra = _infra;
        token = _token;
        owner = _owner;
    }

    function claim() external returns (uint256 paid) {
        uint256 amount = infra.earned(address(this));
        infra.getRewardForUser(address(this));
        paid = _performDepositRewardByRewardType(amount);
    }

    function _performDepositRewardByRewardType(uint256 _amount) internal returns (uint256) {
        _amount = _amount + token.balanceOf(address(this));
        if (_amount == 0) return 0;
        token.transfer(owner, _amount);
        forwarded = forwarded + _amount;
        return _amount;
    }
}

contract Finding55624Test is Test {
    address internal constant OWNER = address(0xBEEF);

    function test_exploit_locks_rewards_in_the_metavault() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.claimable(), 1000 ether, "was claimable");
        assertEq(e.earnedAfter(), 0, "accounting cleared");
        assertEq(e.stuck(), 1000 ether, "stuck");
        assertEq(e.ownerBal(), 0, "owner got nothing");
        assertEq(e.token().balanceOf(address(e.meta())), 1000 ether, "vault holds 1000");
        assertEq(e.meta().forwarded(), 0, "claim paid 0");
    }

    function test_control_owner_can_claim_the_rewards() public {
        Reward token = new Reward();
        InfraredVault infra = new InfraredVault(token);
        MetaVaultFixed meta = new MetaVaultFixed(infra, token, OWNER);
        infra.seed(address(meta), 1000 ether);
        infra.getRewardForUser(address(meta));
        assertEq(token.balanceOf(address(meta)), 1000 ether, "pushed onto the vault");
        meta.claim();
        assertEq(token.balanceOf(OWNER), 1000 ether, "owner claimed 1000");
        assertEq(token.balanceOf(address(meta)), 0, "vault swept");
        assertEq(meta.forwarded(), 1000 ether, "forwarded");
    }
}
