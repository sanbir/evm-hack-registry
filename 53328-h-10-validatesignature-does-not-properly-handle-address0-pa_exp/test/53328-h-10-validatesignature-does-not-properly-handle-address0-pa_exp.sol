// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    DynamicAccountFixed,
    Exploit,
    Usdc
} from "./53328-h-10-validatesignature-does-not-properly-handle-address0-pa.sol";

contract Finding53328Test is Test {
    function test_exploit_zero_signature_moves_funds() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.recovered(), address(0), "ecrecover returned address(0)");
        assertEq(e.moved(), 1000, "1000 USDC moved");
        assertEq(e.token().balanceOf(address(this)), 1000, "caller received 1000");
        assertEq(e.token().balanceOf(address(e.account())), 0, "account emptied");
    }

    function test_control_rejects_address_zero() public {
        Usdc token = new Usdc();
        DynamicAccountFixed account = new DynamicAccountFixed(address(token));
        token.mint(address(account), 1000);

        bytes memory signature = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        account.execute(address(this), 1000, signature);

        assertEq(token.balanceOf(address(this)), 0, "control paid nothing");
        assertEq(token.balanceOf(address(account)), 1000, "1000 stayed in the account");
    }
}
