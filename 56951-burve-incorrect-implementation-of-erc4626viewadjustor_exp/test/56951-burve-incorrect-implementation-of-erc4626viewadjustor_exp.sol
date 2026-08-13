// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, E4626ViewAdjustor, LstVault, PoolManager, MiniERC20} from "./56951-burve-incorrect-implementation-of-erc4626viewadjustor.sol";

// Burve H-2 (finding 56951): E4626ViewAdjustor.toNominal/toReal are reversed.
// toReal (nominal->real) wrongly uses convertToAssets, so sizing a single-token
// deposit for a 1.1x-peg LST charges 110e18 shares instead of the fair ~90.9e18.
contract Finding56951Test is Test {
    function test_exploit_reversedAdjustor_overpays() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("user paid (real shares)", e.userPaid());
        emit log_named_uint("fair requirement", e.fairReal());
        emit log_named_uint("overpaid (stuck)", e.overpaid());

        assertEq(e.userPaid(), 110 ether, "buggy toReal charged convertToAssets amount");
        assertEq(e.fairReal(), uint256(100 ether * 10) / 11, "fair amount is convertToShares(100)");
        assertGt(e.overpaid(), 19 ether, "user overpaid ~19.09e18 shares");
    }
}
