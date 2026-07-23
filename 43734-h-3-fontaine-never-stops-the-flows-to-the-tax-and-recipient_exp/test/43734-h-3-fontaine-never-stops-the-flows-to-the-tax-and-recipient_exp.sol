// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./43734-h-3-fontaine-never-stops-the-flows-to-the-tax-and-recipient.sol";

/*//////////////////////////////////////////////////////////////
    Superfluid Fontaine — buffer never reclaimed (H-3, #43734)

    - test_exploit: drives Exploit; re-asserts buffer permanently locked.
    - test_control_stopReclaimsBuffer: control — stopFlow returns buffer.
//////////////////////////////////////////////////////////////*/
contract FontaineBufferLossTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        uint256 locked = e.fluid().lockedBuffer(address(e.fontaine()));
        uint256 received =
            e.fluid().balanceOf(address(e.recipient())) + e.fluid().balanceOf(address(e.taxPool()));
        assertGt(locked, 3 ether, "buffer locked");
        assertEq(received + locked, e.UNLOCK_AMOUNT(), "conservation");
        assertLt(received, e.UNLOCK_AMOUNT(), "recipient+tax shorted by buffer");
    }

    function test_control_stopReclaimsBuffer() public {
        MockFluid fluid = new MockFluid();
        address tax = address(0x71A1);
        address rec = address(0x4EC1);
        Fontaine f = new Fontaine(fluid, tax);
        fluid.mint(address(f), 10_000 ether);

        // Open flows via initialize
        f.initialize(rec, int96(int256(2e14)), int96(int256(22222222222222)));
        uint256 buf = fluid.lockedBuffer(address(f));
        assertGt(buf, 0);

        // CONTROL FIX: stopFlow reclaims buffer (what Fontaine lacks).
        vm.prank(address(f));
        fluid.stopFlow(rec);
        assertEq(fluid.lockedBuffer(address(f)), 0, "buffer reclaimed");
        assertGe(fluid.balanceOf(address(f)), buf, "buffer returned to fontaine");
    }
}
