// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    MockUSDT,
    ProjectOwner,
    TreasuryFixed,
    Whitelist
} from "./37616-missing-decimals-conversion-in-settleprojectownerfunds-zokyo.sol";

contract Finding37616Test is Test {
    function test_exploit_owner_paid_unscaled_amount() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.paid(), 1000, "owner paid 1000 raw units");
        assertEq(e.fairPay(), 1_000_000_000, "fair pay is 1000 * 10**6");
        assertEq(e.retained(), 999_999_000, "shortfall stays in the treasury");
        assertEq(e.usdt().balanceOf(address(e.projectOwner())), 1000, "owner balance");
        assertEq(e.usdt().balanceOf(address(e.treasury())), 999_999_000, "treasury balance");
        assertEq(e.usdt().decimals(), 6, "USDT decimals");
    }

    function test_control_scales_by_decimals() public {
        MockUSDT usdt = new MockUSDT();
        ProjectOwner projectOwner = new ProjectOwner();
        TreasuryFixed treasury = new TreasuryFixed(address(usdt));
        uint256 scale = 10 ** uint256(usdt.decimals());
        uint256 fair = 1000 * scale;
        usdt.mint(address(treasury), fair);
        treasury.fundProject(1, fair);

        Whitelist memory users = Whitelist({
            userAddress: address(projectOwner),
            projectId: 1,
            amount: 1000,
            inETH: false,
            platformFee: 0
        });
        treasury.settleProjectOwnerFunds(users);

        assertEq(usdt.balanceOf(address(projectOwner)), fair, "control pays 1000000000");
        assertEq(usdt.balanceOf(address(treasury)), 0, "treasury emptied");
        assertEq(treasury.projectTotalCollectedInUSDT(1), 0, "collected cleared");
    }
}
