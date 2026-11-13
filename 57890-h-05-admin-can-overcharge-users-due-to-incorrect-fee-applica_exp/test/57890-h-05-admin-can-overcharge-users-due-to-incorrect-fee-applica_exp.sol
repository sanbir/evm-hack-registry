// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Asset,
    Exploit,
    FundContractFixed
} from "./57890-h-05-admin-can-overcharge-users-due-to-incorrect-fee-applica.sol";

contract Finding57890Test is Test {
    function test_withdrawal_charges_the_management_fee() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.charged(), 100 ether, "charged");
        assertEq(e.fair(), 3.5 ether, "fair trading fee");
        assertEq(e.charged() - e.fair(), 96.5 ether, "overcharge");
        assertEq(e.feeGot(), 100 ether, "fee receiver");
        assertEq(e.userGot(), 9900 ether, "user net");
    }

    function test_control_charges_the_trading_fee() public {
        Asset asset = new Asset();
        address feeReceiver = address(0xFEE);
        FundContractFixed fund = new FundContractFixed(asset, feeReceiver);
        fund.initiateWithdrawal(10_000 ether);
        asset.mint(address(fund), 10_000 ether);
        fund.withdraw(10_000 ether);
        assertEq(asset.balanceOf(feeReceiver), 3.5 ether, "fair 3.5");
        assertEq(asset.balanceOf(address(this)), 9996.5 ether, "user keeps the 96.5");
    }
}
