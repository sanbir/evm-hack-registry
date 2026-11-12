// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Paladin ValkyrieHooklet — afterSwap is gated by onlyBunniHub, but Bunni
    calls it from BunniHook (Cyfrin / Draiakoo, finding #61559, 12 March 2025).

    SYNTHETIC, cheatcode-free. The pool calls afterSwap. The modifier requires
    msg.sender == bunniHub, so the swap reverts and N = 1000 IN stays with
    the user. The fixed hook uses onlyBunniHook and the same swap pays
    1000 OUT. */

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

contract BunniHub {}

contract ValkyrieHooklet {
    address public immutable bunniHub;

    constructor(address bunniHub_) {
        bunniHub = bunniHub_;
    }

    modifier onlyBunniHub() {
        // @> VULN: BunniHook is the caller, so this hub check reverts every swap
        require(msg.sender == bunniHub, "hub");
        _;
    }

    function afterSwap() external onlyBunniHub returns (bytes4) {
        return ValkyrieHooklet.afterSwap.selector;
    }
}

contract ValkyrieHookletFixed {
    address public bunniHook;

    function setBunniHook(address bunniHook_) external {
        bunniHook = bunniHook_;
    }

    modifier onlyBunniHook() {
        require(msg.sender == bunniHook, "hook");
        _;
    }

    function afterSwap() external onlyBunniHook returns (bytes4) {
        return ValkyrieHookletFixed.afterSwap.selector;
    }
}

contract Pool {
    Token public tokenIn;
    Token public tokenOut;
    address public hook;

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
        (bool success,) = hook.call(abi.encodeWithSignature("afterSwap()"));
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

    Token public tokenIn;
    Token public tokenOut;
    BunniHub public hub;
    ValkyrieHooklet public hooklet;
    Pool public pool;

    constructor() {
        tokenIn = new Token("In", "IN", 18);
        tokenOut = new Token("Out", "OUT", 18);
        hub = new BunniHub();
        hooklet = new ValkyrieHooklet(address(hub));
        pool = new Pool(tokenIn, tokenOut, address(hooklet));
    }

    function run() external {
        tokenIn.mint(address(this), N);
        tokenOut.mint(address(this), N);
        tokenIn.approve(address(pool), N);
        tokenOut.approve(address(pool), N);
        pool.fund(N);
        (bool ok, uint256 outAmt) = pool.swap(N);
        require(!ok, "swap should revert");
        require(outAmt == 0, "output was paid");
        require(tokenIn.balanceOf(address(this)) == N, "N did not stay with the user");
        require(tokenOut.balanceOf(address(this)) == 0, "user received output");
        require(tokenOut.balanceOf(address(pool)) == N, "output still in the pool");
    }
}
