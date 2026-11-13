// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Satori TokenRoyaltiesHandler — strict equality reverts a rounded purchase
    (Sigma Prime, finding 19564).
    SYNTHETIC, cheatcode-free. The require(totalPaid == purchaseCost) line is
    the audited check (@> VULN). Two 50% royalty legs on a cost of 10001 round
    down to 5000 + 5000. The equality fails, so the NFT stays with the handler
    and the 10001 payment stays there. The control uses >= and delivers the NFT. */

contract MockToken {
    string public name = "PAY";
    string public symbol = "PAY";
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(uint8 _decimals) {
        decimals = _decimals;
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

contract Royalties {
    mapping(address => uint256) public recorded;

    function recordRoyalties(address who, uint256 amount) external {
        recorded[who] += amount;
    }
}

contract NFT {
    mapping(uint256 => address) public ownerOf;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function transfer(address to, uint256 id) external {
        ownerOf[id] = to;
    }
}

contract TokenRoyaltiesHandler {
    MockToken public pay;
    Royalties public royalties;
    NFT public nft;
    address public buyer;
    address[] public entities;
    uint256[] public bps;
    uint256 public totalPaid;
    bool public delivered;

    constructor(address _pay, address _royalties, address _nft, address _buyer, address a, address b) {
        pay = MockToken(_pay);
        royalties = Royalties(_royalties);
        nft = NFT(_nft);
        buyer = _buyer;
        entities.push(a);
        entities.push(b);
        bps.push(5000);
        bps.push(5000);
    }

    function purchased(uint256 tokenId, uint256 purchaseCost) external {
        uint256 paid = 0;
        for (uint256 i = 0; i < entities.length; ++i) {
            uint256 owed = bps[i] * purchaseCost / 10000;
            paid += owed;
            royalties.recordRoyalties(entities[i], owed);
        }
        totalPaid = paid;
        // @> VULN: rounded legs sum to 10000, so == 10001 reverts and the NFT is not delivered
        require(paid == purchaseCost, "Royalties payment not calculated correctly");
        nft.transfer(buyer, tokenId);
        delivered = true;
    }
}

contract TokenRoyaltiesHandlerFixed {
    MockToken public pay;
    Royalties public royalties;
    NFT public nft;
    address public buyer;
    address[] public entities;
    uint256[] public bps;
    bool public delivered;

    constructor(address _pay, address _royalties, address _nft, address _buyer, address a, address b) {
        pay = MockToken(_pay);
        royalties = Royalties(_royalties);
        nft = NFT(_nft);
        buyer = _buyer;
        entities.push(a);
        entities.push(b);
        bps.push(5000);
        bps.push(5000);
    }

    function purchased(uint256 tokenId, uint256 purchaseCost) external {
        uint256 paid = 0;
        for (uint256 i = 0; i < entities.length; ++i) {
            uint256 owed = bps[i] * purchaseCost / 10000;
            paid += owed;
            royalties.recordRoyalties(entities[i], owed);
            pay.transfer(entities[i], owed);
        }
        // FIX: accept the rounded-down total instead of requiring an exact match
        require(purchaseCost >= paid, "Royalties payment not calculated correctly");
        nft.transfer(buyer, tokenId);
        delivered = true;
    }
}

contract Exploit {
    MockToken public pay;
    Royalties public royalties;
    NFT public nft;
    TokenRoyaltiesHandler public handler;
    address public buyer;
    address public royaltyA;
    address public royaltyB;
    uint256 public constant COST = 10001;
    uint256 public constant TOKEN_ID = 1;

    constructor() {
        pay = new MockToken(0);
        royalties = new Royalties();
        nft = new NFT();
        buyer = address(new Buyer());
        royaltyA = address(new Receiver());
        royaltyB = address(new Receiver());
        handler = new TokenRoyaltiesHandler(
            address(pay), address(royalties), address(nft), buyer, royaltyA, royaltyB
        );
        nft.mint(address(handler), TOKEN_ID);
    }

    function run() external {
        pay.mint(address(handler), COST);
        (bool ok,) = address(handler).call(
            abi.encodeWithSelector(handler.purchased.selector, TOKEN_ID, COST)
        );
        require(!ok, "buy should revert");
        require(pay.balanceOf(address(handler)) == COST, "payment stuck");
        require(nft.ownerOf(TOKEN_ID) == address(handler), "nft stayed");
        require(handler.delivered() == false, "not delivered");
        require(royalties.recorded(royaltyA) == 0, "royalty rolled back");
    }
}

contract Buyer {}
contract Receiver {}
