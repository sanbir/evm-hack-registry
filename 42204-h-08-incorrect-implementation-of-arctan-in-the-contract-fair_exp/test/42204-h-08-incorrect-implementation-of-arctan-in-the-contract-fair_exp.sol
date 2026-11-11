// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, FairSideFormula, Fsd} from "./42204-h-08-incorrect-implementation-of-arctan-in-the-contract-fair.sol";

/// Report's corrected _arctan: abs(a) in both (a - 1) and APPROX_B * a.
contract FixedCurve {
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
        int256 aa = a < 0 ? -a : a;
        int256 linear = mul(a, PI_4);
        int256 corr = mul(mul(a, aa - ONE), APPROX_A + mul(APPROX_B, aa));
        return linear - corr;
    }

    function buy(int256 capital) external returns (uint256 paid) {
        int256 arcInner = MULTIPLIER * capital / FS34;
        int256 a = ONE - arcInner;
        int256 delta = _arctan(a);
        paid = uint256(delta < 0 ? -delta : delta);
        fsd.mint(msg.sender, paid);
    }
}

contract Finding42204Test is Test {
    function test_exploit_overpays_89200000000000000() public {
        Exploit e = new Exploit();
        e.run();
        uint256 paid = e.fsd().balanceOf(address(e));
        int256 fairSigned = e.curve().fairDelta(1 ether);
        uint256 fairPay = uint256(-fairSigned);
        console.log("paid FSD", paid);
        console.log("fair FSD", fairPay);
        console.log("overpay", paid - fairPay);
        assertEq(paid, 551361581698724154, "buggy payout");
        assertEq(fairPay, 462161581698724154, "report fair payout");
        assertEq(paid - fairPay, 89200000000000000, "overpay");
        assertEq(e.curve().calculateDeltaOfFSD(int256(0.5 ether)), e.curve().fairDelta(int256(0.5 ether)));
    }

    function test_control_abs_formula_pays_fair() public {
        Fsd fsd = new Fsd();
        FixedCurve fixedCurve = new FixedCurve(fsd);
        uint256 paid = fixedCurve.buy(1 ether);
        assertEq(paid, 462161581698724154, "control pays the report value");
        assertEq(fsd.balanceOf(address(this)), 462161581698724154, "minted fair amount");
        assertEq(fsd.totalSupply(), 462161581698724154);
    }
}
