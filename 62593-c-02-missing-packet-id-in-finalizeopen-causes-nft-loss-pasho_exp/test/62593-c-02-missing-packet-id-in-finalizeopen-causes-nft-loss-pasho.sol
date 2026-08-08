// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    RipIt - Missing packet ID in finalizeOpen() causes NFT loss
    (Pashov Audit Group, 2025-05, finding #62593, C-02)

    SYNTHETIC, cheatcode-free reduction.

    Root cause: finalizeOpen builds `uint256[] memory packetIds = new uint256[](1)`
    but never assigns packetIds[0] = packetId before addPacketsToInventory.
    The array is [0]; inventory validation reverts. Combined with initiateBurn
    already transferring the NFT into the Packet contract, the open path reverts
    and the NFT is stuck - user loses the packet with no cards in return.
//////////////////////////////////////////////////////////////////////////*/

error InvalidPacketType(uint256 packetTypeId);

contract PacketStore {
    mapping(uint256 => bool) public validPacketType;
    mapping(uint256 => bool) public inInventory;

    function setValidType(uint256 t, bool v) external {
        validPacketType[t] = v;
    }

    function _validatePacketTypeId(uint256 packetTypeId) internal view returns (bool) {
        return validPacketType[packetTypeId];
    }

    function addPacketsToInventory(uint256[] memory packetIds) external {
        for (uint256 i = 0; i < packetIds.length; i++) {
            uint256 packetTypeId = packetIds[i]; // in real code: lookup type by id; 0 is invalid
            if (!_validatePacketTypeId(packetTypeId)) revert InvalidPacketType(packetTypeId);
            inInventory[packetIds[i]] = true;
        }
    }
}

/// @notice Minimal ERC721-like Packet NFT with the vulnerable finalizeOpen.
contract Packet {
    enum BurnType {
        NONE,
        INSTANT_OPEN_PACKET,
        SLOW_OPEN
    }

    PacketStore public immutable packetStore;
    address public allocationManager;

    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => BurnType) public burnTypeOf;
    mapping(uint256 => bool) public burned; // stuck/burned flag
    mapping(uint256 => uint256) public packetTypeIdOf;
    mapping(address => mapping(address => mapping(uint256 => bool))) public approved;

    uint256 public nextId = 1;

    constructor(PacketStore _store) {
        packetStore = _store;
        allocationManager = msg.sender;
    }

    function setAllocationManager(address a) external {
        allocationManager = a;
    }

    function mintTo(address to, uint256 packetTypeId) external returns (uint256 packetId) {
        packetId = nextId++;
        ownerOf[packetId] = to;
        packetTypeIdOf[packetId] = packetTypeId;
    }

    function approve(address spender, uint256 packetId) external {
        require(msg.sender == ownerOf[packetId] || msg.sender == address(this), "auth");
        approved[ownerOf[packetId]][spender][packetId] = true;
    }

    function _transfer(address from, address to, uint256 packetId) internal {
        require(ownerOf[packetId] == from, "owner");
        ownerOf[packetId] = to;
    }

    /// @notice User initiates instant open: NFT is pulled into this contract and
    ///         marked for INSTANT_OPEN; finalizeOpen is then expected to complete.
    function initiateBurn(uint256 packetId) external {
        require(ownerOf[packetId] == msg.sender, "not owner");
        burnTypeOf[packetId] = BurnType.INSTANT_OPEN_PACKET;
        // Pull NFT into the packet contract (user no longer holds it)
        _transfer(msg.sender, address(this), packetId);
        burned[packetId] = true; // marked as in-flight burn
    }

    /// @notice Vulnerable finalizeOpen - missing packetIds[0] = packetId.
    function finalizeOpen(uint256 packetId, uint256[] memory /*selectedBundle*/, string memory /*openMetadata*/)
        external
    {
        require(msg.sender == allocationManager, "only manager");
        BurnType burnType = burnTypeOf[packetId];

        if (burnType == BurnType.INSTANT_OPEN_PACKET) {
            // NFT already held by this contract from initiateBurn; re-approve store
            // (mirrors production: _transfer(ownerOf, this) + approve store)
            if (ownerOf[packetId] != address(this)) {
                _transfer(ownerOf[packetId], address(this), packetId);
            }
            this.approve(address(packetStore), packetId);

            uint256[] memory packetIds = new uint256[](1);
            // Missing: packetIds[0] = packetId; FIX: packetIds[0] = packetId;
            // packetIds[0] remains 0 -> addPacketsToInventory reverts InvalidPacketType(0)
            packetStore.addPacketsToInventory(packetIds); // @> VULN: array never assigned packetId
        } else {
            // slow path omitted
        }
        // success path would clear burn and mint cards - never reached for INSTANT_OPEN
        burnTypeOf[packetId] = BurnType.NONE;
    }

    function isStuck(uint256 packetId) external view returns (bool) {
        return burned[packetId] && ownerOf[packetId] == address(this) && burnTypeOf[packetId] == BurnType.INSTANT_OPEN_PACKET;
    }
}

contract Exploit {
    PacketStore public store; // 1
    Packet public packet; // 2 vulnerable
    address public user; // 3

    uint256 public packetId;

    constructor() {
        store = new PacketStore();
        packet = new Packet(store);
        user = address(new UserHelper());

        store.setValidType(1, true); // type 1 valid; type 0 is NOT
        // packet is allocationManager (constructor msg.sender = Exploit)

        // Mint packet NFT to user
        packetId = packet.mintTo(user, 1);
    }

    function run() external {
        // User initiates burn (NFT leaves user → stuck in Packet)
        UserHelper(user).doInitiate(packet, packetId);
        require(packet.ownerOf(packetId) == address(packet), "nft in packet");
        require(packet.burned(packetId), "burn marked");

        // Manager tries finalizeOpen - reverts because packetIds[0]==0
        bool reverted;
        try packet.finalizeOpen(packetId, new uint256[](0), "") {
            reverted = false;
        } catch {
            reverted = true;
        }
        require(reverted, "finalizeOpen should revert");

        // HARM: NFT stuck in contract, burn still INSTANT_OPEN, user has nothing
        require(packet.isStuck(packetId), "packet stuck: NFT lost, no cards");
        require(packet.ownerOf(packetId) != user, "user no longer owns NFT");
    }
}

contract UserHelper {
    function doInitiate(Packet p, uint256 id) external {
        p.initiateBurn(id);
    }
}
