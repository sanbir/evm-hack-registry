// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./50881-non-refunded-excess-fee-in-setpricesfrompricefeed-function.sol";

/*//////////////////////////////////////////////////////////////
    NLX — non-refunded excess fee in _setPricesFromPriceFeeds (#50881)

    - test_exploit: drives the cheatcode-free Exploit end to end.
    - test_excessTrapped_standalone: rebuilds the overpay path with EOAs.
//////////////////////////////////////////////////////////////*/
contract ExcessFeeNotRefundedTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        vm.deal(address(e), e.SENT());
        e.run();

        // Re-assert harm: excess stays on the oracle module.
        assertEq(address(e.oracle()).balance, e.EXCESS(), "excess trapped on oracle");
        assertEq(address(e.pyth()).balance, e.FEE(), "pyth holds only the fee");
    }

    function test_excessTrapped_standalone() public {
        MockPyth pyth = new MockPyth();
        OracleModule oracle = new OracleModule(pyth);

        address caller = makeAddr("caller");
        uint256 sent = 0.02 ether;
        uint256 fee = 0.01 ether;
        vm.deal(caller, sent);

        address[] memory tokens = new address[](0);
        bytes[] memory data = new bytes[](0);

        uint256 before = caller.balance;
        vm.prank(caller);
        oracle.setPricesFromPriceFeeds{value: sent}(tokens, data);

        assertEq(before - caller.balance, sent, "no refund of excess");
        assertEq(address(oracle).balance, sent - fee, "excess trapped");
        assertEq(address(pyth).balance, fee, "fee forwarded to pyth");
    }
}
