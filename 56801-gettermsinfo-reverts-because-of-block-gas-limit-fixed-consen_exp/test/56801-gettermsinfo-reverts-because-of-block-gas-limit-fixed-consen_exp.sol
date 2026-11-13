// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    Mini,
    MultiTokenPeriodEnforcerFixed
} from "./56801-gettermsinfo-reverts-because-of-block-gas-limit-fixed-consen.sol";

contract Finding56801Test is Test {
    address internal constant RECEIVER = 0x3333333333333333333333333333333333333333;

    function test_exploit_late_token_stays_locked() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.decodedLast(), 1_000 ether, "the last record really is 1000");
        assertGt(e.gasLast(), e.cap(), "the full scan costs more than the cap");
        assertEq(e.earlyOk(), 1, "index 0 still redeems inside the cap");
        assertEq(e.lateOk(), 0, "the last token reverts inside the same cap");
        assertEq(e.lockedLeft(), 1_000 ether, "1000 tokens never moved");
        assertEq(Mini(address(e.token())).balanceOf(RECEIVER), 100 ether, "only the early 100 moved");
        emit log_named_uint("gasFirst", e.gasFirst());
        emit log_named_uint("gasLast", e.gasLast());
        emit log_named_uint("cap", e.cap());
    }

    function test_control_index_redeems_under_same_shape() public {
        Mini token = new Mini();
        MultiTokenPeriodEnforcerFixed fixedEnforcer = new MultiTokenPeriodEnforcerFixed(token);
        token.mint(address(fixedEnforcer), 1_000 ether);

        uint256 n = 200;
        bytes memory terms = new bytes(n * 116);
        for (uint256 i; i < n; ++i) {
            address who = i + 1 == n ? address(token) : address(uint160(0xA000 + i));
            uint256 amount = i + 1 == n ? uint256(1_000 ether) : uint256(1 ether);
            uint256 off = i * 116;
            assembly {
                let p := add(add(terms, 32), off)
                mstore(p, shl(96, who))
                mstore(add(p, 20), amount)
                mstore(add(p, 52), 86400)
                mstore(add(p, 84), 1)
            }
        }

        uint256 g0 = gasleft();
        fixedEnforcer.redeem(terms, address(token), RECEIVER, n - 1);
        uint256 used = g0 - gasleft();

        assertEq(token.balanceOf(RECEIVER), 1_000 ether, "indexed redeem moved 1000");
        assertEq(token.balanceOf(address(fixedEnforcer)), 0, "nothing left locked");
        assertLt(used, 200_000, "indexed path is far under a full scan");
    }
}
