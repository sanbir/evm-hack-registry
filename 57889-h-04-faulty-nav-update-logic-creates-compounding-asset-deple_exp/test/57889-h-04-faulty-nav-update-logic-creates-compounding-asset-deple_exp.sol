// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, FundFixed, MockToken} from "./57889-h-04-faulty-nav-update-logic-creates-compounding-asset-deple.sol";

contract NavDoubleCountTest is Test {
    address internal constant FEE = 0x0000000000000000000000000000000000000B0b;

    function test_exploit_navAndAssetsDropBy1100() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.dropped(), 1100 ether, "drop");
        assertEq(e.navAfter(), 8900 ether, "nav");
        assertEq(e.assetsAfter(), 8900 ether, "assets");
        assertEq(e.fairNav(), 9000 ether, "fair");
        assertEq(e.shortfall(), 100 ether, "short 100");
        assertEq(e.feePaid(), 100 ether, "fee pulled again");
    }

    function test_control_keepsTheFeeInsideTheWithdrawal() public {
        MockToken token = new MockToken();
        FundFixed fund = new FundFixed(address(token), FEE);
        fund.fundNav(10000 ether);
        uint256 paid = fund.withdraw(1000 ether);

        assertEq(paid, 1000 ether, "gross paid once");
        assertEq(fund.nav(), 9000 ether, "nav drops by the gross only");
        assertEq(token.balanceOf(address(fund)), 9000 ether, "vault keeps the 100");
        assertEq(token.balanceOf(FEE), 0, "fee is not pulled a second time");
    }
}
