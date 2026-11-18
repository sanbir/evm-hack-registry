// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Debita Finance V3 buyOrder — H-5 (Sherlock 2024-11, issue 890)
    sellNFT delivers the receipt NFT to the buy-order contract and pays the
    seller. The order is then deleted. Nothing transfers the NFT to the creator,
    so the creator paid AERO and does not own the receipt.
*/

contract MockToken {
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s) {
        symbol = s;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}

contract MockNFT {
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => address) public approved;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function approve(address s, uint256 id) external {
        require(ownerOf[id] == msg.sender, "not owner");
        approved[id] = s;
    }

    function transferFrom(address f, address t, uint256 id) external {
        require(ownerOf[id] == f, "from");
        require(msg.sender == f || approved[id] == msg.sender, "auth");
        ownerOf[id] = t;
        approved[id] = address(0);
    }
}

contract BuyOrder {
    MockToken public aero;
    MockNFT public nft;
    address public creator;
    uint256 public price;
    bool public active;
    uint256 public constant PRICE = 1000 ether;
    event OrderFilled(uint256 receiptId);

    constructor(MockToken _aero, MockNFT _nft) {
        aero = _aero;
        nft = _nft;
    }

    function createBuyOrder() external {
        creator = msg.sender; // @beat:create
        price = PRICE;
        active = true;
        aero.transferFrom(msg.sender, address(this), PRICE);
    }

    function sellNFT(uint256 receiptID) external {
        require(active, "no order");
        nft.transferFrom(msg.sender, address(this), receiptID); // @> VULN: NFT is delivered to the order contract, not the creator
        // FIX: nft.transferFrom(msg.sender, creator, receiptID);
        aero.transfer(msg.sender, price); // @beat:pay
        active = false;
        creator = address(0); // @beat:delete
        emit OrderFilled(receiptID);
    }

    function sellNFTFixed(uint256 receiptID) external {
        require(active, "no order");
        address who = creator;
        nft.transferFrom(msg.sender, who, receiptID);
        aero.transfer(msg.sender, price);
        active = false;
        creator = address(0);
    }
}

contract Creator {
    function open(BuyOrder o, MockToken t) external {
        t.approve(address(o), type(uint256).max);
        o.createBuyOrder();
    }
}

contract Seller {
    function sell(BuyOrder o, MockNFT n, uint256 id) external {
        n.approve(address(o), id);
        o.sellNFT(id); // @beat:sell
    }
}

contract Exploit {
    MockToken public aero;
    MockNFT public nft;
    BuyOrder public order;
    Creator public creator;
    Seller public seller;
    uint256 public constant ID = 1;
    address public nftOwnerAfter;

    constructor() {
        aero = new MockToken("AERO"); // nonce 1
        nft = new MockNFT(); // nonce 2
        order = new BuyOrder(aero, nft); // nonce 3
        creator = new Creator(); // nonce 4
        seller = new Seller(); // nonce 5
    }

    function run() external {
        aero.mint(address(creator), 1000 ether);
        nft.mint(address(seller), ID);
        creator.open(order, aero); // @beat:open
        seller.sell(order, nft, ID);
        nftOwnerAfter = nft.ownerOf(ID); // @beat:owner
        require(nftOwnerAfter == address(order), "NFT stuck in the order");
        require(nft.ownerOf(ID) != address(creator), "creator did not receive the NFT");
        require(aero.balanceOf(address(seller)) == 1000 ether, "seller was paid");
        require(aero.balanceOf(address(creator)) == 0, "creator paid and was not refunded");
        require(order.creator() == address(0), "order deleted");
        require(order.active() == false, "order closed");
    }
}
