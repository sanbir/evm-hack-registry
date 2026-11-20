// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, DETokenFixed} from
    "./66501-c-04-incorrect-detoken-interest-causes-pool-drainage-and-los.sol";

contract Finding66501Test is Test {
    address internal constant ALICE = 0x2222222222222222222222222222222222222222;
    address internal constant BOB = 0x1111111111111111111111111111111111111111;
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_interest_uses_the_post_transfer_balance() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.token().lastInterest(), 440 ether, "440 interest");
        assertEq(e.marker().balanceOf(SINK), 400 ether, "400 extra");
    }

    function test_control_interest_uses_the_prior_balance() public {
        DETokenFixed token = new DETokenFixed();
        token.seed(ALICE, 1000 ether, 1.5 ether);
        token.seed(BOB, 100 ether, 1.1 ether);
        uint256 interest = token.transfer(ALICE, BOB, 1000 ether);
        assertEq(interest, 40 ether, "only the 100 he already held");
        assertEq(token.deposits(BOB), 1100 ether, "tokens still move");
    }
}
