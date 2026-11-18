// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Share, ExternalFeeStrategy, FeeRecipient} from "./46434-externalfee-contract-treats-newly-deposit-vault-share-as-yie.sol";

contract Finding46434Test is Test {
    function test_exploit_share_deposit_pays_five_percent_immediately() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.strategy().lastCredited(), 95_000 ether);
        assertEq(e.shares().balanceOf(e.feeRecipient()), 5_000 ether);
        assertEq(e.shares().balanceOf(address(e.strategy())), 95_000 ether);
        assertEq(e.strategy().performanceFees(), 5_000 ether);
    }

    function test_control_underlying_deposit_charges_no_yield_fee() public {
        Share shares = new Share();
        ExternalFeeStrategy s = new ExternalFeeStrategy(shares, address(new FeeRecipient()));
        uint256 credited = s.depositAsset(100_000 ether);
        assertEq(credited, 100_000 ether, "full credit");
        assertEq(s.performanceFees(), 0, "no fee");
        assertEq(shares.balanceOf(address(s)), 100_000 ether, "shares stay");
    }
}
