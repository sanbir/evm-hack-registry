// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    HookPolicy,
    IPolicy,
    ISmartSessions,
    IValidator,
    Session,
    SmartAccount,
    Usd,
    YesValidator
} from "./42067-installation-reentrancy-concerns-cantina-none-biconomy-pdf.sol";

/// PR 102 order: policies (and their external init) run before the session is enabled
/// and before the validator is installed. The callback cannot pass isValidSignature.
contract FixedSessions {
    bytes4 public constant MAGIC = 0x1626ba7e;
    bytes4 public constant FAIL = 0xffffffff;

    mapping(address => bool) public sessionEnabled;
    mapping(address => address) public validatorOf;
    mapping(address => bool) public erc1271Installed;
    mapping(address => bool) public actionPolicySet;

    function enableSessions(Session[] calldata sessions) external returns (bytes32[] memory permissionIds) {
        uint256 length = sessions.length;
        require(length != 0, "InvalidData");
        permissionIds = new bytes32[](length);
        for (uint256 i; i < length; i++) {
            Session calldata session = sessions[i];
            address smartAccount = msg.sender;
            bytes32 permissionId = keccak256(abi.encode(session.sessionValidator, session.policy, smartAccount));

            IPolicy(session.policy).initializeWithMultiplexer(smartAccount, permissionId, session.policyInit);

            sessionEnabled[smartAccount] = true;
            validatorOf[smartAccount] = session.sessionValidator;
            IValidator(session.sessionValidator).onEnable(smartAccount, permissionId);
            erc1271Installed[smartAccount] = true;
            actionPolicySet[smartAccount] = true;
            permissionIds[i] = permissionId;
        }
    }

    function isValidSignature(bytes32, bytes calldata) external view returns (bytes4) {
        address account = msg.sender;
        if (!sessionEnabled[account]) return FAIL;
        if (validatorOf[account] == address(0)) return FAIL;
        if (erc1271Installed[account]) return FAIL;
        return MAGIC;
    }
}

/// Same callback the policy uses. Swallows the revert so the fixed install can finish.
contract Probe {
    SmartAccount public account;

    constructor(SmartAccount _account) {
        account = _account;
    }

    function installExecutor(address module, address token, uint256 amount, bytes32 hash) external {
        try account.installExecutor(module, token, amount, hash) {
            revert("control installed a module");
        } catch {}
    }
}

contract Finding42067Test is Test {
    function test_exploit_second_module_drains_1000() public {
        Exploit e = new Exploit();
        e.run();
        uint256 stolen = e.usd().balanceOf(address(e));
        uint256 left = e.usd().balanceOf(address(e.account()));
        console.log("stolen USD", stolen);
        console.log("account USD", left);
        console.log("moduleCount", e.account().moduleCount());
        assertEq(stolen, 1000 ether, "module took 1000 USD");
        assertEq(left, 0, "account left with 0");
        assertEq(e.account().moduleCount(), 2, "second module installed");
        assertEq(e.account().executor(), address(e));
        assertTrue(e.sessions().erc1271Installed(address(e.account())));
    }

    function test_control_reorder_blocks_second_module() public {
        Usd usd = new Usd();
        HookPolicy policy = new HookPolicy();
        YesValidator validator = new YesValidator();
        FixedSessions fixedSessions = new FixedSessions();
        SmartAccount acct = new SmartAccount(ISmartSessions(address(fixedSessions)), usd, validator);
        Probe probe = new Probe(acct);
        usd.mint(address(acct), 1000 ether);
        bytes memory initData =
            abi.encode(address(probe), address(usd), uint256(1000 ether), keccak256("smart-sessions-drain"));
        acct.enableLimitedSession(address(policy), initData);

        assertEq(usd.balanceOf(address(acct)), 1000 ether, "account keeps 1000");
        assertEq(usd.balanceOf(address(probe)), 0, "probe received nothing");
        assertEq(acct.moduleCount(), 1, "no second module");
        assertEq(acct.executor(), address(0));
        assertTrue(fixedSessions.sessionEnabled(address(acct)));
        assertTrue(fixedSessions.erc1271Installed(address(acct)));
    }
}
