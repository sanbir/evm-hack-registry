// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, VaultFixed} from
    "./35125-h-12-the-withdrawvalue-calculation-in-calculatevalueofwithd.sol";

contract Finding35125Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_unfinalized_split_is_valued_at_100() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.vault().lastValue(), 100 ether, "full value");
        assertEq(e.marker().balanceOf(SINK), 60 ether, "over by 60");
    }

    function test_control_scales_the_piece_to_40() public {
        VaultFixed vault = new VaultFixed();
        VaultFixed.WithdrawRequest memory w =
            VaultFixed.WithdrawRequest({requestId: 1, vaultShares: 40 ether, hasSplit: true});
        assertEq(vault.valueOf(w, 100 ether, 100 ether), 40 ether, "40 of 100");
    }
}
