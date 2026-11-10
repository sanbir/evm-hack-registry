// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    TreasuryFixed,
    Whitelist
} from "./37615-incorrect-handling-of-investment-amounts-zokyo-none-devve-ma.sol";

contract Finding37615Test is Test {
    address internal constant OWNER = 0x2222222222222222222222222222222222222222;

    function test_exploit_owner_is_paid_the_credited_amount_not_the_eth_sent() public {
        vm.deal(address(this), 50 ether);
        Exploit e = new Exploit();
        e.run{value: 40 ether}();

        assertEq(e.invested(), 40 ether, "investor sent 40 ETH");
        assertEq(e.credited(), 10 ether, "investor was credited 10 ETH");
        assertEq(e.paid(), 10 ether, "owner was paid 10 ETH");
        assertEq(OWNER.balance, 10 ether, "owner balance");
        assertEq(address(e.treasury()).balance, 30 ether, "30 ETH stuck in the treasury");
    }

    function test_control_records_and_pays_the_real_amount() public {
        vm.deal(address(this), 50 ether);
        TreasuryFixed treasury = new TreasuryFixed();
        Whitelist memory users = Whitelist({
            userAddress: OWNER,
            projectId: 1,
            amount: 40 ether,
            inETH: true,
            platformFee: 0
        });
        treasury.investInProjects{value: 40 ether}(users);
        treasury.settleProjectOwnerFunds(users);

        assertEq(treasury.creditedAmount(1, address(this)), 40 ether, "credited the real 40");
        assertEq(treasury.investorInvestedAmountPerProjectInETH(1, address(this)), 40 ether, "invested 40");
        assertEq(OWNER.balance, 40 ether, "owner was paid the real 40");
        assertEq(address(treasury).balance, 0, "treasury is empty");
    }
}
