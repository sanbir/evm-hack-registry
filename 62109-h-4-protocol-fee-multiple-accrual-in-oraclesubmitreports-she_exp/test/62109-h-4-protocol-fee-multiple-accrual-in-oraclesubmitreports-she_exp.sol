// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./62109-h-4-protocol-fee-multiple-accrual-in-oraclesubmitreports-she.sol";

contract Mellow62109Test is Test {
    function test_exploit() public {
        // Ensure one year has elapsed for fee math (playground uses anvil_state clock).
        vm.warp(1_700_000_000);
        Exploit e = new Exploit();
        e.run();
        assertGt(e.feeShares(), 300 ether, "triple+ fee accrual");
        assertEq(e.expectedSingle(), 100 ether, "single year 10% of 1000");
        assertGt(e.excessFees(), 200 ether, "excess over single accrual");
    }

    function test_singleBaseReport_accruesOnce() public {
        vm.warp(1_700_000_000);
        FeeManager feeManager = new FeeManager();
        ShareManager shareManager = new ShareManager();
        Vault vault = new Vault(feeManager, shareManager);
        Oracle oracle = new Oracle(vault);

        feeManager.setFeeRecipient(address(0xFEE));
        feeManager.setFees(1e5);
        feeManager.setBaseAsset(address(vault), address(0xA0));
        shareManager.mint(address(0x100), 1000 ether);
        feeManager.setTimestamp(address(vault), block.timestamp - 365 days);

        Oracle.Report[] memory reports = new Oracle.Report[](1);
        reports[0] = Oracle.Report({asset: address(0xA0), priceD18: 1e18});
        oracle.submitReports(reports);

        assertEq(shareManager.sharesOf(address(0xFEE)), 100 ether, "single accrual");
    }
}
