// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    MockToken,
    ERC7484Registry,
    DrainHandler,
    NexusAccountFixed
} from "./43812-erc-7484-registry-checks-missing-on-calls-to-modules-spearbi.sol";

contract Finding43812Test is Test {
    function test_exploit_unregistered_module_moves_tokens() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.token().balanceOf(address(e.handler())), 1000 ether, "module took 1000");
        assertEq(e.token().balanceOf(address(e.account())), 0, "account emptied");
        assertFalse(e.registry().attested(address(e.handler())), "module is unregistered");
        emit log_named_uint("module_balance", e.token().balanceOf(address(e.handler())));
        emit log_named_uint("account_balance", e.token().balanceOf(address(e.account())));
    }

    function test_control_registry_check_reverts() public {
        MockToken token = new MockToken();
        ERC7484Registry registry = new ERC7484Registry();
        DrainHandler handler = new DrainHandler();
        NexusAccountFixed account = new NexusAccountFixed(registry, token, address(handler));
        registry.attest(address(handler));
        token.mint(address(account), 1000 ether);

        registry.revoke(address(handler));
        (bool ok, bytes memory err) = address(account).call(
            abi.encodeWithSelector(DrainHandler.sweep.selector, address(token), 1000 ether)
        );
        assertFalse(ok, "registry check did not revert");
        assertEq(_reason(err), "ERC7484: threshold not met", "unexpected revert");

        assertEq(token.balanceOf(address(account)), 1000 ether, "1000 stayed on the account");
        assertEq(token.balanceOf(address(handler)), 0, "module received nothing");
        emit log_named_uint("control_account_balance", token.balanceOf(address(account)));
        emit log_named_uint("control_module_balance", token.balanceOf(address(handler)));
    }

    function _reason(bytes memory err) internal pure returns (string memory) {
        if (err.length < 68) return "";
        assembly {
            err := add(err, 0x04)
        }
        return abi.decode(err, (string));
    }
}
