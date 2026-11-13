// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Usdc, ZenoFixed, AuctionFixed} from
    "./57151-zeno-token-redemption-returns-negligible-usdc-amount-compare.sol";

contract Finding57151Test is Test {
    function test_exploit_redeem_pays_100_usdc_units_instead_of_100_usdc() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.returned(), 100, "100 base units");
        assertEq(e.retained(), 100 * 10 ** 6 - 100, "99.9999 USDC retained");
        assertEq(e.zeno().balanceOf(address(e)), 0, "bonds burned");
        assertEq(e.usdc().balanceOf(e.BUSINESS()), 100 * 99_998_959, "purchase paid");
        assertEq(e.usdc().balanceOf(address(e)), 104_200, "buyer left with 0.1042 USDC");
    }

    function test_control_scaled_redeem_pays_100_usdc() public {
        Usdc usdc = new Usdc();
        ZenoFixed zeno = new ZenoFixed(usdc, 1);
        AuctionFixed auction = new AuctionFixed(usdc, zeno, address(0xBEEF));
        zeno.setMinter(address(auction));
        usdc.mint(address(this), 10_000 * 10 ** 6);
        usdc.approve(address(auction), type(uint256).max);
        auction.buy(100);
        usdc.mint(address(zeno), 100 * 10 ** 6);

        uint256 beforeBal = usdc.balanceOf(address(this));
        zeno.redeem(100);
        assertEq(usdc.balanceOf(address(this)) - beforeBal, 100 * 10 ** 6, "100 USDC");
        assertEq(usdc.balanceOf(address(zeno)), 0, "reserve paid out");
        assertEq(zeno.balanceOf(address(this)), 0, "burned");
    }
}
