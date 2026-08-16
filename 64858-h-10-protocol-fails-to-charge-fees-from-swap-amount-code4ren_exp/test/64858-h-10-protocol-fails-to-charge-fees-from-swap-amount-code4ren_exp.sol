// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;
import "forge-std/Test.sol";
import {Exploit, GTELaunchpadV2Pair, MiniToken} from "./64858-h-10-protocol-fails-to-charge-fees-from-swap-amount-code4ren.sol";
contract Finding64858Test is Test {
    function test_launchpadFeeLeak() public {
        Exploit e = new Exploit();
        e.run();
        emit log_named_uint("leaked to distributor", e.leakedToDistributor());
        assertGt(e.leakedToDistributor(), 0, "unbacked launchpad fee leaked from LP reserves");
    }
}
