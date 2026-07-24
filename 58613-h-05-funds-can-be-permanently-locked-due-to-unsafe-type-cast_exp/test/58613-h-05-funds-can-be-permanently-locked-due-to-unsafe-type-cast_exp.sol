// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./58613-h-05-funds-can-be-permanently-locked-due-to-unsafe-type-cast.sol";

contract KinetiqUnsafeCastTest is Test {
    function test_exploit_uint64CastLocksFunds() public {
        Exploit e = new Exploit();
        uint256 amount = uint256(type(uint64).max) + 1;
        e.run{value: amount}();

        assertEq(uint256(e.delegated()), 0, "delegated 0 after cast");
        assertEq(e.locked(), amount, "full amount stuck on manager");
        assertEq(e.minted(), amount, "full kHYPE minted");
        assertEq(address(e.manager()).balance, amount);
    }

    function test_control_smallStakeDelegatesFully() public {
        KHYPE k = new KHYPE();
        L1Write l1 = new L1Write();
        StakingManager m = new StakingManager(k, l1, address(0xA11));
        m.stake{value: 1 ether}();
        assertEq(uint256(l1.lastAmount()), 1 ether, "full amount delegated");
        assertEq(k.balanceOf(address(this)), 1 ether);
    }

    receive() external payable {}
}
