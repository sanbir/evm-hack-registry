// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    IActionPolicy,
    LimitUsage,
    ParamRule,
    SmartAccount,
    Usd,
    VALIDATION_FAILED,
    VALIDATION_SUCCESS
} from "./42095-uniactionpolicy-does-not-persist-usages-cantina-none-biconom.sol";

/// PR 76: check takes ParamRule storage and is not view, so used accumulates.
contract FixedPolicy is IActionPolicy {
    mapping(address => ParamRule) internal rules;

    function initialize(address account, uint256 limit) external {
        ParamRule storage rule = rules[account];
        rule.offset = 32;
        rule.isLimited = true;
        rule.usage.limit = limit;
        rule.usage.used = 0;
    }

    function used(address account) external view returns (uint256) {
        return rules[account].usage.used;
    }

    function limitOf(address account) external view returns (uint256) {
        return rules[account].usage.limit;
    }

    function checkAction(address account, uint256 value, bytes calldata data) external returns (uint256) {
        require(value == 0, "value");
        if (!check(rules[account], data)) return VALIDATION_FAILED;
        return VALIDATION_SUCCESS;
    }

    function check(ParamRule storage rule, bytes calldata data) internal returns (bool) {
        bytes32 param = bytes32(data[4 + rule.offset:4 + rule.offset + 32]);
        if (rule.isLimited) {
            if (rule.usage.used + uint256(param) > rule.usage.limit) return false;
            rule.usage.used += uint256(param);
        }
        return true;
    }
}

contract Finding42095Test is Test {
    function test_exploit_two_spends_exceed_limit_by_20() public {
        Exploit e = new Exploit();
        e.run();
        uint256 taken = e.usd().balanceOf(address(e));
        uint256 left = e.usd().balanceOf(address(e.account()));
        uint256 storedUsed = e.policy().used(address(e.account()));
        console.log("taken USD", taken);
        console.log("account USD", left);
        console.log("stored used", storedUsed);
        assertEq(taken, 120 ether, "120 moved");
        assertEq(left, 0, "account emptied");
        assertEq(storedUsed, 0, "usage stayed 0");
        assertEq(taken - e.policy().limitOf(address(e.account())), 20 ether, "20 over the 100 limit");
    }

    function test_control_persisted_usage_reverts_second_spend() public {
        Usd usd = new Usd();
        FixedPolicy policy = new FixedPolicy();
        SmartAccount account = new SmartAccount(IActionPolicy(address(policy)), usd);
        usd.mint(address(account), 120 ether);
        policy.initialize(address(account), 100 ether);

        account.spend(60 ether);
        assertEq(policy.used(address(account)), 60 ether, "first spend stored");
        assertEq(usd.balanceOf(address(this)), 60 ether, "only 60 so far");

        vm.expectRevert("limit");
        account.spend(60 ether);

        assertEq(usd.balanceOf(address(this)), 60 ether, "second spend moved nothing");
        assertEq(usd.balanceOf(address(account)), 60 ether, "60 stayed under the limit");
        assertEq(policy.used(address(account)), 60 ether, "used stayed 60");
    }
}
