// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, FundFixed, MockToken} from "./57887-h-02-incorrect-fee-calculation-period-leads-to-overcharging.sol";

contract FeePeriodTest is Test {
    address internal constant FEE = 0x0000000000000000000000000000000000000B0b;
    uint256 internal constant NOW = 1_700_000_000;
    uint256 internal constant NAV = 1000 ether;
    uint256 internal constant CHARGED = 84931528320000000000;
    uint256 internal constant FAIR = 2739726720000000000;

    function test_exploit_charges31DaysInsteadOf1() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.period(), 31 days, "period");
        assertEq(e.charged(), CHARGED, "charged");
        assertEq(e.fair(), FAIR, "fair");
        assertEq(e.extra(), CHARGED - FAIR, "extra");
        assertEq(e.token().balanceOf(FEE), CHARGED, "receiver");
    }

    function test_control_firstDepositClockChargesTheFairDay() public {
        MockToken token = new MockToken();
        FundFixed fund = new FundFixed(address(token));
        fund.setupVaultSetting(NOW - 31 days, 100, FEE);
        fund.deposit(NAV, NOW - 1 days);
        uint256 paid = fund.harvest(NOW);
        assertEq(paid, FAIR, "control pays the 1 day fee");
        assertEq(token.balanceOf(FEE), FAIR, "receiver got the fair fee");
        assertLt(paid, CHARGED, "control is not the 31 day charge");
    }
}
