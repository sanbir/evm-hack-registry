// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, USDC, HinkalFixed} from "./60148-the-protocol-can-be-drained-through-commitment-duplication-q.sol";

contract Finding60148Test is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    function test_exploit_withdraws_victim_million() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.withdrawn(), 2_000_001e6, "withdrew old plus new commitment");
        assertEq(e.token().balanceOf(ATTACKER), 2_000_001e6, "attacker balance");
        assertEq(e.withdrawn() - 1_000_001e6, 1_000_000e6, "1,000,000 USDC stolen");
        assertEq(e.token().balanceOf(address(e.hinkal())), 0, "pool empty");
    }

    function test_control_duplicate_input_reverts() public {
        USDC token = new USDC();
        HinkalFixed h = new HinkalFixed(token);
        uint256[] memory honest = new uint256[](1);
        honest[0] = 7;
        h.registerProof(honest);
        token.mint(address(this), 1_000_001e6);
        token.approve(address(h), 1_000_001e6);
        h.deposit(7, 1_000_001e6);
        token.mint(address(this), 1_000_000e6);
        token.approve(address(h), 1_000_000e6);
        h.deposit(11, 1_000_000e6);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 7;
        uint256[] memory emptyNulls = new uint256[](0);
        uint256[] memory newNulls = new uint256[](2);
        newNulls[0] = 8;
        newNulls[1] = 9;
        uint256[] memory newAmounts = new uint256[](2);
        newAmounts[0] = 1_000_000e6;
        newAmounts[1] = 1e6;
        address[] memory newOwners = new address[](2);
        newOwners[0] = address(this);
        newOwners[1] = address(0x4444);
        bool reverted;
        try h.transact(tokenIds, emptyNulls, newNulls, newAmounts, newOwners) {
            reverted = false;
        } catch {
            reverted = true;
        }
        assertTrue(reverted, "swapped nullifiers rejected");
        h.withdraw(7, address(this));
        assertEq(token.balanceOf(address(this)), 1_000_001e6, "only own deposit returns");
        assertEq(token.balanceOf(address(h)), 1_000_000e6, "other deposit stays");
    }
}
