// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {
    Exploit,
    GondiPoolFixed,
    IGondiPool,
    PoolAsset
} from "./35209-h-07-deploywithdrawalqueue-need-to-clear-queueaccountinglas.sol";

contract Finding35209Test is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    function test_stale_accounting_pays_32_unearned() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.unearned(), 32 ether, "recycled queue received 32");
        assertEq(e.legitSlice(), 20 ether, "active queue received its 20 slice");
        assertEq(e.attackerGot(), 32 ether, "attacker withdrew 32");
        assertEq(e.recycledFraction(), 4e19, "index 0 still holds the old fraction");
        assertEq(e.asset().balanceOf(ATTACKER), 32 ether, "attacker balance");
        assertEq(e.pool().thisQueueFraction(0), 4e19, "stale slot");
        assertEq(e.pool().thisQueueFraction(2), 2e19, "queue 2 fraction");

        console2.log("unearned", e.unearned());
        console2.log("legit slice", e.legitSlice());
        console2.log("attacker", e.attackerGot());
        console2.log("recycled fraction", e.recycledFraction());
    }

    function test_control_clear_on_deploy_pays_new_queue_nothing() public {
        PoolAsset asset = new PoolAsset();
        GondiPoolFixed fixedPool = new GondiPoolFixed(asset);
        Exploit e = new Exploit();
        e.runOn(IGondiPool(address(fixedPool)), asset);

        assertEq(e.recycledFraction(), 0, "delete cleared index 0");
        assertEq(e.unearned(), 0, "recycled queue was not paid");
        assertEq(e.legitSlice(), 20 ether, "active queue still received 20");
        assertEq(e.attackerGot(), 0, "attacker withdrew 0");
        assertEq(asset.balanceOf(ATTACKER), 0, "attacker balance stays 0");
        assertEq(fixedPool.thisQueueFraction(0), 0, "slot is zero");
        assertEq(fixedPool.thisQueueFraction(2), 2e19, "queue 2 fraction unchanged");
        assertEq(asset.balanceOf(fixedPool.queueAddress(0)), 0, "new queue holds nothing");

        console2.log("control unearned", e.unearned());
        console2.log("control legit slice", e.legitSlice());
        console2.log("control attacker", e.attackerGot());
    }
}
