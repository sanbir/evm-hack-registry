// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    BeraBitcoin,
    BeraBitcoinFixed,
    Treasury
} from "./55099-c-01-protocol-loses-mintredeem-fees-due-to-missing-treasury.sol";

contract Finding55099Test is Test {
    function test_exploit_fees_burned_and_treasury_stays_zero() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.FEE(), 100 ether, "fee unit");
        assertEq(e.feesLost(), 200 ether, "200 fees lost in total");
        assertEq(e.redeemFeeBurned(), 100 ether, "100 redeem fee burned");
        assertEq(e.mintFeeLost(), 100 ether, "100 mint fee never minted");
        assertEq(e.treasuryBalance(), 0, "treasury is 0");
        assertEq(e.contractBalance(), 0, "fee is not sitting in the contract");
        assertEq(e.token().balanceOf(address(e.treasury())), 0, "treasury token balance 0");

        emit log_named_uint("HARM redeem fee burned", e.redeemFeeBurned());
        emit log_named_uint("HARM mint fee never minted", e.mintFeeLost());
        emit log_named_uint("HARM treasury balance", e.treasuryBalance());
    }

    function test_control_forwards_both_fees_to_treasury() public {
        Treasury treasury = new Treasury();
        BeraBitcoinFixed token = new BeraBitcoinFixed(address(treasury));

        uint256 gross = 1000 ether;
        uint256 fee = 100 ether;

        token.seed(address(this), gross);
        token.redeem(gross, "bc1q-control");
        assertEq(token.balanceOf(address(treasury)), fee, "redeem fee forwarded");

        token.custodianMint(address(this), gross);
        assertEq(token.balanceOf(address(treasury)), fee + fee, "mint fee forwarded too");
        assertEq(token.balanceOf(address(this)), gross - fee, "minter received net");

        emit log_named_uint("CONTROL treasury balance", token.balanceOf(address(treasury)));
    }
}
