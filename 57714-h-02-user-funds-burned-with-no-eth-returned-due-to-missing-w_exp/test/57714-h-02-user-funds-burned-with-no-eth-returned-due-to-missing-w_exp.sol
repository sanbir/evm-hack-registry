// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import {Asset, Exploit, StPlumeMinterFixed, Validator} from "./57714-h-02-user-funds-burned-with-no-eth-returned-due-to-missing-w.sol";

contract Finding57714Test is Test {
    function test_validator_unstake_burns_frx_and_pays_zero() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.burned(), 10 ether, "10 frxETH burned");
        assertEq(e.requestAmount(), 0, "no withdrawal request");
        assertEq(e.paid(), 0, "withdraw pays 0");
        assertEq(e.stuck(), 10 ether, "10 WETH stuck in the minter");
        assertEq(e.weth().balanceOf(address(e)), 0, "user received no WETH");
    }

    function test_control_writes_the_request_and_pays() public {
        Asset frx = new Asset("frxETH", "frxETH");
        Asset weth = new Asset("WETH", "WETH");
        Validator plume = new Validator(weth);
        StPlumeMinterFixed minter = new StPlumeMinterFixed(frx, weth, plume);
        frx.mint(address(this), 10 ether);
        weth.mint(address(plume), 10 ether);
        minter.unstakeFromValidator(10 ether, 1);
        assertEq(minter.requestOf(address(this)), 10 ether, "request saved");
        uint256 paid = minter.withdraw(address(this));
        assertEq(paid, 10 ether, "10 WETH returned");
        assertEq(weth.balanceOf(address(minter)), 0, "minter empty");
    }
}
