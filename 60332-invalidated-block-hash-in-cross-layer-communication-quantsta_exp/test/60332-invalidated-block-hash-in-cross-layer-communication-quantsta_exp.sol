// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    ChildFixed,
    Exploit,
    Token
} from "./60332-invalidated-block-hash-in-cross-layer-communication-quantsta.sol";

contract Finding60332Test is Test {
    function test_exploit_zero_hash_blocks_the_proof() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.paid(), 0, "valid proof paid out");
        assertEq(e.stuck(), e.N(), "escrow did not keep N");
        assertEq(e.token().balanceOf(address(e.child())), 250 ether);
        assertEq(e.child().blockHashs(42), bytes32(0));
    }

    function test_control_rejects_zero_and_pays_n() public {
        Token token = new Token("Bridge USD", "bUSD", 18);
        ChildFixed child = new ChildFixed(token);
        bytes32 realHash = keccak256("pheasant-block-42");
        token.mint(address(this), 250 ether);
        token.approve(address(child), 250 ether);
        child.deposit(250 ether);
        child.optimismSendBlockInfo(42, realHash);

        (bool wiped,) = address(child).call(
            abi.encodeWithSelector(ChildFixed.optimismSendBlockInfo.selector, uint256(42), bytes32(0))
        );
        assertFalse(wiped, "zero hash was stored");

        uint256 paid = child.claim(realHash);
        assertEq(paid, 250 ether, "control did not pay N");
        assertEq(token.balanceOf(address(child)), 0, "escrow still holds N");
        assertEq(token.balanceOf(address(this)), 250 ether, "claimer did not receive N");
    }
}
