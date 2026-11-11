// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    ISpendPolicy,
    SmartAccount,
    TokenPolicyData,
    Usd,
    VALIDATION_FAILED,
    VALIDATION_SUCCESS
} from "./42096-erc20spendinglimitpolicy-doesnt-clear-previous-data-cantina.sol";

/// PR 117: wipe previous alreadySpent before the new spendingLimit is stored.
contract FixedPolicy is ISpendPolicy {
    mapping(address => mapping(address => TokenPolicyData)) internal data_;
    mapping(address => address[]) internal listed;

    function seed(address account, address token, uint256 limit, uint256 spent) external {
        TokenPolicyData storage $ = data_[account][token];
        if ($.spendingLimit == 0 && $.alreadySpent == 0) listed[account].push(token);
        $.spendingLimit = limit;
        $.alreadySpent = spent;
    }

    function spendingLimit(address account, address token) external view returns (uint256) {
        return data_[account][token].spendingLimit;
    }

    function alreadySpent(address account, address token) external view returns (uint256) {
        return data_[account][token].alreadySpent;
    }

    function initializeWithMultiplexer(address account, bytes calldata initData) external {
        address[] storage prev = listed[account];
        for (uint256 i; i < prev.length; i++) {
            TokenPolicyData storage oldData = data_[account][prev[i]];
            oldData.spendingLimit = 0;
            oldData.alreadySpent = 0;
        }
        delete listed[account];

        (address[] memory tokens, uint256[] memory limits) = abi.decode(initData, (address[], uint256[]));
        for (uint256 i; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 limit = limits[i];
            require(token != address(0), "token");
            require(limit != 0, "limit");
            TokenPolicyData storage $ = data_[account][token];
            $.spendingLimit = limit;
            $.alreadySpent = 0;
            listed[account].push(token);
        }
    }

    function checkAction(address account, address target, uint256 value, bytes calldata callData)
        external
        returns (uint256)
    {
        if (value != 0) return VALIDATION_FAILED;
        (, uint256 amount) = abi.decode(callData[4:], (address, uint256));
        TokenPolicyData storage $ = data_[account][target];
        uint256 newAmount = $.alreadySpent + amount;
        if (newAmount > $.spendingLimit) return VALIDATION_FAILED;
        $.alreadySpent = newAmount;
        return VALIDATION_SUCCESS;
    }
}

contract Finding42096Test is Test {
    function test_exploit_fresh_limit_locks_30() public {
        Exploit e = new Exploit();
        e.run();
        uint256 locked = e.usd().balanceOf(address(e.account()));
        uint256 spent = e.policy().alreadySpent(address(e.account()), address(e.usd()));
        uint256 limit = e.policy().spendingLimit(address(e.account()), address(e.usd()));
        console.log("locked USD", locked);
        console.log("alreadySpent", spent);
        console.log("limit", limit);
        assertEq(locked, 30 ether, "30 stayed locked");
        assertEq(spent, 80 ether, "old usage kept");
        assertEq(limit, 100 ether, "new limit stored");
        assertEq(limit - spent, 20 ether, "only 20 usable");
        assertEq(e.usd().balanceOf(address(e)), 0, "spender received nothing");
    }

    function test_control_clears_old_usage_and_30_moves() public {
        Usd usd = new Usd();
        FixedPolicy policy = new FixedPolicy();
        SmartAccount account = new SmartAccount(ISpendPolicy(address(policy)), usd);
        usd.mint(address(account), 30 ether);
        policy.seed(address(account), address(usd), 100 ether, 80 ether);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usd);
        uint256[] memory limits = new uint256[](1);
        limits[0] = 100 ether;
        policy.initializeWithMultiplexer(address(account), abi.encode(tokens, limits));

        assertEq(policy.alreadySpent(address(account), address(usd)), 0, "old usage cleared");
        assertEq(policy.spendingLimit(address(account), address(usd)), 100 ether, "new limit");

        account.spend(30 ether);
        assertEq(usd.balanceOf(address(this)), 30 ether, "30 moved");
        assertEq(usd.balanceOf(address(account)), 0, "account emptied");
        assertEq(policy.alreadySpent(address(account), address(usd)), 30 ether, "new usage is 30");
    }
}
