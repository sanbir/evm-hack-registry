// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, Token, ERC20AssetAdapterFixed, LendingPoolFixed} from
    "./66190-h-28-deposits-during-liquidation-enable-collateral-lockup-pa.sol";

contract Finding66190Test is Test {
    function test_exploit_one_wei_deposit_locks_1000_collateral() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.liquidationReverted(), "liquidation reverted");
        assertTrue(e.withdrawReverted(), "withdraw frozen");
        assertEq(e.locked(), 1000 ether + 1, "adapter holds collateral");
        assertEq(e.recorded(), 1000 ether + 1, "balance no longer matches");
        assertEq(e.token().balanceOf(address(e.adapter())), 1000 ether + 1, "tokens stuck");
    }

    function test_control_blocks_the_deposit_and_seizes_collateral() public {
        Token token = new Token();
        ERC20AssetAdapterFixed adapter = new ERC20AssetAdapterFixed(token);
        LendingPoolFixed pool = new LendingPoolFixed(adapter);
        adapter.setLendingPool(address(pool));
        token.mint(address(this), 1000 ether + 1);
        token.approve(address(adapter), 1000 ether + 1);
        pool.openVault();
        pool.depositAsset(abi.encode(uint256(1000 ether)));
        pool.initiateLiquidation(address(this));

        vm.expectRevert(ERC20AssetAdapterFixed.DepositsDisabledDuringLiquidation.selector);
        pool.depositAsset(abi.encode(uint256(1)));

        pool.liquidate(address(this), abi.encode(uint256(1000 ether)));

        assertEq(token.balanceOf(address(adapter)), 0, "adapter empty");
        assertEq(token.balanceOf(address(this)), 1000 ether + 1, "collateral returned to liquidator");
    }
}
