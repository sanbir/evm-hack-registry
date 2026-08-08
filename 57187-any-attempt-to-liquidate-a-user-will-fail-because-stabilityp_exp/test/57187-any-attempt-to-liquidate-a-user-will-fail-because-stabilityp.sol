// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Unknown / Codehawks — Any attempt to liquidate a user will fail because
    StabilityPool does not hold crvUSD during its operational lifecycle
    (s4muraii77, finding #57187)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: StabilityPool.liquidateBorrower checks
    `crvUSDToken.balanceOf(address(this))` and reverts InsufficientBalance
    when the balance is below the borrower's scaled debt. Across the protocol
    lifecycle, crvUSD deposited/repaid is routed to reserveRTokenAddress (or
    kept in other contracts) — never into StabilityPool — so the balance is
    always 0 and every liquidation reverts. Undercollateralized positions
    cannot be closed → bad debt / broken solvency.

    Vulnerable balance check preserved with @> VULN markers.
    FIX: fund StabilityPool with crvUSD, or pull from reserveRTokenAddress. */

error InsufficientBalance();
error InvalidAmount();
error ApprovalFailed();

contract MockCrvUSD {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Minimal lending pool: tracks debt; deposits go to a reserve, NOT the SP.
contract LendingPool {
    MockCrvUSD public immutable crvUSD;
    address public immutable reserveRTokenAddress;
    mapping(address => uint256) public userDebt;
    mapping(address => bool) public liquidated;
    uint256 public constant NORMALIZED_DEBT = 1e27; // ray = 1.0

    constructor(MockCrvUSD t, address reserve) {
        crvUSD = t;
        reserveRTokenAddress = reserve;
    }

    function getUserDebt(address user) external view returns (uint256) {
        return userDebt[user];
    }

    function getNormalizedDebt() external pure returns (uint256) {
        return NORMALIZED_DEBT;
    }

    /// @dev Deposit routes crvUSD to the reserve — never to StabilityPool.
    function deposit(address from, uint256 amount) external {
        crvUSD.transferFrom(from, reserveRTokenAddress, amount);
    }

    function setDebt(address user, uint256 debt) external {
        userDebt[user] = debt;
    }

    function updateState() external {}

    function finalizeLiquidation(address user) external {
        // Would burn debt using crvUSD approved by StabilityPool.
        userDebt[user] = 0;
        liquidated[user] = true;
    }
}

/// @dev Reduced StabilityPool with the broken liquidateBorrower balance check.
contract StabilityPool {
    address public owner;
    MockCrvUSD public crvUSDToken;
    LendingPool public lendingPool;
    bool public paused;

    constructor(address owner_) {
        owner = owner_;
    }

    function initialize(address crvUSD_, address lendingPool_) external {
        require(msg.sender == owner, "only owner");
        crvUSDToken = MockCrvUSD(crvUSD_);
        lendingPool = LendingPool(lendingPool_);
    }

    function _update() internal {}

    /// @dev rayMul simplified: amount * ray / 1e27.
    function _rayMul(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b) / 1e27;
    }

    /// @dev Vulnerable liquidateBorrower (StabilityPool.sol).
    function liquidateBorrower(address userAddress) external {
        require(msg.sender == owner, "onlyManagerOrOwner");
        require(!paused, "paused");
        _update();
        uint256 userDebt = lendingPool.getUserDebt(userAddress);
        uint256 scaledUserDebt = _rayMul(userDebt, lendingPool.getNormalizedDebt());
        if (userDebt == 0) revert InvalidAmount();
        uint256 crvUSDBalance = crvUSDToken.balanceOf(address(this)); // @> VULN: SP never holds crvUSD
        if (crvUSDBalance < scaledUserDebt) revert InsufficientBalance(); // @> VULN: always reverts in lifecycle
        // FIX: pull scaledUserDebt from reserveRTokenAddress (or keep crvUSD here)
        bool approveSuccess = crvUSDToken.approve(address(lendingPool), scaledUserDebt);
        if (!approveSuccess) revert ApprovalFailed();
        lendingPool.updateState();
        lendingPool.finalizeLiquidation(userAddress);
    }
}

/// @dev Holds the reserve where deposits actually land.
contract Reserve {
    // empty holder of crvUSD routed by LendingPool.deposit
}

contract Exploit {
    MockCrvUSD public crvUSD; // CREATE nonce 1
    Reserve public reserve; // CREATE nonce 2
    LendingPool public lendingPool; // CREATE nonce 3
    StabilityPool public stabilityPool; // CREATE nonce 4 — vulnerable
    address public borrower; // EOA-like: address(this) used as borrower identity via setDebt

    bool public liquidationReverted;
    uint256 public spCrvBalance;
    uint256 public reserveCrvBalance;
    bool public borrowerStillInDebt;

    constructor() {
        crvUSD = new MockCrvUSD();
        reserve = new Reserve();
        lendingPool = new LendingPool(crvUSD, address(reserve));
        // StabilityPool owner = this (Exploit) so run() can call liquidateBorrower
        stabilityPool = new StabilityPool(address(this));
        stabilityPool.initialize(address(crvUSD), address(lendingPool));
        borrower = address(uint160(0xB0B));
    }

    function run() external {
        // Simulate operational lifecycle: deposits put crvUSD in the RESERVE, not SP.
        crvUSD.mint(address(this), 10_000e18);
        crvUSD.approve(address(lendingPool), 10_000e18);
        lendingPool.deposit(address(this), 10_000e18);

        // Underwater borrower with 1000 crvUSD debt (normalized ray = 1 → scaled = 1000).
        lendingPool.setDebt(borrower, 1000e18);

        spCrvBalance = crvUSD.balanceOf(address(stabilityPool));
        reserveCrvBalance = crvUSD.balanceOf(address(reserve));
        require(spCrvBalance == 0, "SP should hold zero crvUSD in lifecycle");
        require(reserveCrvBalance == 10_000e18, "reserve holds the deposits");

        // Any liquidation attempt fails: SP balance (0) < scaled debt (1000e18).
        liquidationReverted = !_tryLiquidate(borrower);
        require(liquidationReverted, "harm not demonstrated: liquidation should fail");

        borrowerStillInDebt = lendingPool.getUserDebt(borrower) == 1000e18;
        require(borrowerStillInDebt, "borrower debt should remain (unliquidatable)");
        require(!lendingPool.liquidated(borrower), "must not be liquidated");
    }

    function _tryLiquidate(address user) internal returns (bool ok) {
        try stabilityPool.liquidateBorrower(user) {
            ok = true;
        } catch {
            ok = false;
        }
    }
}
