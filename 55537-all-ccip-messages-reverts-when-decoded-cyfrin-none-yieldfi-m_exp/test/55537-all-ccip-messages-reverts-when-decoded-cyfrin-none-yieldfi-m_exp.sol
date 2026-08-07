// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {BridgeCCIP} from "../src/yieldfi/BridgeCCIP.sol";
import {Codec, BridgeSendPayload} from "../src/yieldfi/Codec.sol";
import {Constants} from "../src/yieldfi/Constants.sol";
import {Client} from "../src/chainlink/Client.sol";

/// @dev Minimal REAL ERC20 standing in for the opaque bridged yToken. Only the
/// surface `BridgeCCIP.send` touches (`balanceOf`) is needed; it is a genuine
/// token contract so `Common.isContract(token)` holds.
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }
}

/// @dev The opaque CCIP boundary. We control it (it is the configured router),
/// exactly as Chainlink's real Router would be. It captures what the source
/// `BridgeCCIP.send` emits via `ccipSend`, then relays it to the destination
/// `BridgeCCIP` via `ccipReceive` — i.e. faithful cross-chain transport. It
/// invents nothing about the payload; the bytes come straight from real `send`.
contract RouterDouble {
    uint64 public lastSelector;
    bytes public lastData;

    function isChainSupported(uint64) external pure returns (bool) { return true; }
    function getFee(uint64, Client.EVM2AnyMessage memory) external pure returns (uint256) { return 0; }

    function ccipSend(uint64 dstChain, Client.EVM2AnyMessage calldata message)
        external
        payable
        returns (bytes32)
    {
        lastSelector = dstChain;
        lastData = message.data;
        return keccak256(abi.encode(dstChain, message.data));
    }

    function deliver(BridgeCCIP dest, uint64 sourceSelector, address sender) external {
        Client.Any2EVMMessage memory m = Client.Any2EVMMessage({
            messageId: keccak256(abi.encode(sourceSelector, lastData)),
            sourceChainSelector: sourceSelector,
            sender: abi.encode(sender),
            data: lastData,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
        dest.ccipReceive(m); // msg.sender == router (this) => passes CCIPReceiver.onlyRouter
    }
}

/// @dev Test-only wrapper to call the internal library function directly (control).
contract CodecHarness {
    function decode(bytes memory data) external view returns (BridgeSendPayload memory) {
        return Codec.decodeBridgeSendPayload(data);
    }
}

contract PoC_55537_CCIPDecodeDoS is Test {
    // Ethereum mainnet CCIP chain selector (docs.chain.link/ccip/directory) — a
    // uint64 far above uint32.max (4_294_967_295).
    uint64 internal constant ETH_CCIP_SELECTOR = 5009297550715157269;
    uint64 internal constant BASE_CCIP_SELECTOR = 15971525489660198786; // dest chain in this scenario

    RouterDouble internal router;
    BridgeCCIP internal srcBridge; // source chain bridge (calls send)
    BridgeCCIP internal dstBridge; // destination chain bridge (receives)
    MockERC20 internal yToken;
    MockERC20 internal remoteToken;
    CodecHarness internal harness;

    address internal user = address(0xA11CE);
    address internal recipient = address(0xB0B);

    function setUp() public {
        router = new RouterDouble();
        // both bridges share the same router double (single-node cross-chain sim)
        srcBridge = new BridgeCCIP(address(router), true);
        dstBridge = new BridgeCCIP(address(router), false);
        yToken = new MockERC20();
        remoteToken = new MockERC20();
        harness = new CodecHarness();

        yToken.mint(user, 1_000 ether);
        // wire the source send path: lockbox present + remote token mapped for BASE
        srcBridge.setLockbox(address(yToken), address(0xDEAD));
        srcBridge.setToken(address(yToken), BASE_CCIP_SELECTOR, address(remoteToken));
    }

    /// End-to-end: a user bridges yToken via the REAL `send` (which packs the
    /// uint64 destination selector), the router relays it, and the REAL
    /// `_ccipReceive` reverts while decoding. The message can never be processed.
    function test_everyCcipMessageRevertsOnDecode() public {
        vm.prank(user);
        srcBridge.send(address(yToken), BASE_CCIP_SELECTOR, recipient, 100 ether, address(dstBridge));

        // sanity: the router actually captured a well-formed 160-byte payload
        bytes memory inner = abi.decode(router.lastData(), (bytes));
        assertEq(inner.length, 160, "payload must be exactly 5 words");

        // HARM: destination decoding reverts -> message stuck forever (no retry,
        // not upgradeable). This is the permanent cross-chain liveness break.
        vm.expectRevert();
        router.deliver(dstBridge, ETH_CCIP_SELECTOR, address(srcBridge));
    }

    /// Isolate the mechanism at the real Codec level: the SAME well-formed
    /// payload reverts iff the first field exceeds uint32.max.
    function test_codec_control_uint32_vs_uint64_selector() public {
        // (a) A uint32-range dstId decodes cleanly through the real Codec.
        bytes memory ok = abi.encode(
            uint64(12345), recipient, address(remoteToken), uint256(100 ether), Constants.BRIDGE_SEND_HASH
        );
        BridgeSendPayload memory p = harness.decode(ok);
        assertEq(uint256(p.dstId), 12345, "in-range selector decodes");
        assertEq(p.amount, 100 ether);

        // (b) The real Ethereum CCIP selector (uint64) on the SAME payload shape
        // reverts at abi.decode into uint32 — this is the bug, in the real Codec.
        bytes memory bad = abi.encode(
            ETH_CCIP_SELECTOR, recipient, address(remoteToken), uint256(100 ether), Constants.BRIDGE_SEND_HASH
        );
        vm.expectRevert();
        harness.decode(bad);

        // Prove it really is > uint32.max (documents WHY every real selector bricks it).
        assertGt(ETH_CCIP_SELECTOR, type(uint32).max);
        assertGt(BASE_CCIP_SELECTOR, type(uint32).max);
    }
}
