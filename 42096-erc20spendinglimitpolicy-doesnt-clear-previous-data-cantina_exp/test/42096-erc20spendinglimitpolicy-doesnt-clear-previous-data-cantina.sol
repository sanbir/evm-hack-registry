// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Biconomy / Rhinestone ERC20SpendingLimitPolicy — re-init keeps old usage
    (Cantina, AuditVault 42096). SYNTHETIC, cheatcode-free.

    Root cause: initializeWithMultiplexer writes spendingLimit and leaves
    alreadySpent (and any token absent from the new list) untouched.

    Verbatim body from the finding, before the alreadySpent = 0 fix:

        TokenPolicyData storage $ = _getPolicy(...);
        $.spendingLimit = limit;

    A previous install spent 80 USD of a 100 USD limit. The owner sets a fresh
    100 USD limit. alreadySpent stays 80. A 30 USD spend, which the new limit
    allows, reverts. 30 USD stays locked. The control clears alreadySpent, and
    that 30 USD spend succeeds. */

uint256 constant VALIDATION_SUCCESS = 0;
uint256 constant VALIDATION_FAILED = 1;

contract Usd {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

struct TokenPolicyData {
    uint256 alreadySpent;
    uint256 spendingLimit;
}

interface ISpendPolicy {
    function seed(address account, address token, uint256 limit, uint256 spent) external;
    function initializeWithMultiplexer(address account, bytes calldata initData) external;
    function checkAction(address account, address target, uint256 value, bytes calldata callData)
        external
        returns (uint256);
    function spendingLimit(address account, address token) external view returns (uint256);
    function alreadySpent(address account, address token) external view returns (uint256);
}

error InvalidTokenAddress(address token);
error InvalidLimit(uint256 limit);

contract ERC20SpendingLimitPolicy is ISpendPolicy {
    mapping(address => mapping(address => TokenPolicyData)) internal data_;

    function seed(address account, address token, uint256 limit, uint256 spent) external {
        TokenPolicyData storage $ = data_[account][token];
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
        (address[] memory tokens, uint256[] memory limits) = abi.decode(initData, (address[], uint256[]));
        for (uint256 i; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 limit = limits[i];
            if (token == address(0)) revert InvalidTokenAddress(token);
            if (limit == 0) revert InvalidLimit(limit);
            TokenPolicyData storage $ = data_[account][token];
            // @> VULN: spendingLimit is replaced and alreadySpent from the previous install is left in place
            $.spendingLimit = limit;
        }
    }

    function checkAction(address account, address target, uint256 value, bytes calldata callData)
        external
        returns (uint256)
    {
        if (value != 0) return VALIDATION_FAILED;
        (, uint256 amount) = abi.decode(callData[4:], (address, uint256));
        TokenPolicyData storage $ = data_[account][target];
        uint256 spentBefore = $.alreadySpent;
        uint256 newAmount = spentBefore + amount;
        if (newAmount > $.spendingLimit) return VALIDATION_FAILED;
        $.alreadySpent = newAmount;
        return VALIDATION_SUCCESS;
    }
}

contract SmartAccount {
    ISpendPolicy public policy;
    Usd public usd;

    constructor(ISpendPolicy _policy, Usd _usd) {
        policy = _policy;
        usd = _usd;
    }

    function spend(uint256 amount) external {
        bytes memory data = abi.encodeWithSelector(bytes4(0xa9059cbb), msg.sender, amount);
        uint256 code = policy.checkAction(address(this), address(usd), 0, data);
        require(code == VALIDATION_SUCCESS, "limit");
        usd.transfer(msg.sender, amount);
    }
}

contract Exploit {
    Usd public usd; // nonce 1
    ERC20SpendingLimitPolicy public policy; // nonce 2
    SmartAccount public account; // nonce 3

    constructor() {
        usd = new Usd();
        policy = new ERC20SpendingLimitPolicy();
        account = new SmartAccount(ISpendPolicy(address(policy)), usd);
    }

    function run() external {
        usd.mint(address(account), 30 ether);
        policy.seed(address(account), address(usd), 100 ether, 80 ether);
        address[] memory tokens = new address[](1);
        tokens[0] = address(usd);
        uint256[] memory limits = new uint256[](1);
        limits[0] = 100 ether;
        policy.initializeWithMultiplexer(address(account), abi.encode(tokens, limits));
        uint256 spent = policy.alreadySpent(address(account), address(usd));
        uint256 limit = policy.spendingLimit(address(account), address(usd));
        (bool ok,) = address(account).call(abi.encodeWithSelector(account.spend.selector, uint256(30 ether)));
        uint256 locked = usd.balanceOf(address(account));
        require(spent == 80 ether, "old usage kept");
        require(limit == 100 ether, "new limit 100");
        require(!ok, "30 should revert");
        require(locked == 30 ether, "30 locked");
        require(limit - spent == 20 ether, "only 20 of the new 100 is usable");
    }
}
