// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {
    CErc20InterestMarketFixed,
    Comptroller,
    Dai,
    Exploit
} from "./62380-fng-17-cerc20interestmarket-collateral-can-be-directly-used.sol";

contract Finding62380Test is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    function test_exploit_interest_payment_creates_bad_debt() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.market().accountTokens(address(e)), 0, "collateral wiped");
        assertEq(e.market().borrowBalance(address(e)), 8.5 ether, "borrow still open");
        assertEq(e.market().badDebt(), 8.5 ether, "8.5 DAI is unbacked");
        assertEq(e.dai().balanceOf(ATTACKER), 8.5 ether, "attacker keeps the DAI");
    }

    function test_control_redeem_check_reverts_and_keeps_collateral() public {
        Dai dai = new Dai();
        Comptroller comptroller = new Comptroller();
        CErc20InterestMarketFixed market = new CErc20InterestMarketFixed(dai, comptroller);

        dai.mint(address(market), 8.5 ether);
        market.mintCollateral(address(this), 10 ether);
        market.borrow(8.5 ether, address(this));

        vm.expectRevert(bytes("redeem not allowed"));
        market.repayBorrowBehalf(address(market), address(this), 10 ether);

        assertEq(market.accountTokens(address(this)), 10 ether, "collateral unchanged");
        assertEq(market.badDebt(), 0, "no bad debt");
        assertEq(market.borrowBalance(address(this)), 8.5 ether, "borrow still backed");
    }
}
