// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./64041-c-01-unrestricted-router-allows-unauthorized-merkle-root-set.sol";

contract AmpleEarnRouterAuthTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.tok().balanceOf(address(e.attacker())), e.STEAL(), "attacker stole vault funds");
        assertEq(e.tok().balanceOf(address(e.vault())), 0, "vault drained");
    }

    function test_directSetWithoutManagerReverts() public {
        MockToken tok = new MockToken();
        address owner = address(this);
        AmpleEarn vault = new AmpleEarn(tok, owner);
        // router is NOT a payout manager
        AmpleEarnRouter router = new AmpleEarnRouter();

        SetMerkleRootsParams[] memory params = new SetMerkleRootsParams[](1);
        params[0] = SetMerkleRootsParams({
            vault: address(vault),
            participantsRoot: bytes32(uint256(1)),
            designatedRecipientsRoot: bytes32(uint256(2)),
            designatedRecipientsCount: 1,
            totalTickets: 1,
            vrfProofDetails: VRFProofDetails({
                proof: bytes32(0), seed: bytes32(0), publicKey: bytes32(0), vrfHash: bytes32(0)
            })
        });

        vm.expectRevert(AmpleErrorsLib.NotPayoutManagerRole.selector);
        router.batchSetMerkleRootsStrict(params);
    }
}
