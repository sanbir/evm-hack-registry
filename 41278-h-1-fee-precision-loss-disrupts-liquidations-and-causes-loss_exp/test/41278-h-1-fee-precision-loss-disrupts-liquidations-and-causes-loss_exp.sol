// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {
    Exploit,
    FeeEngineFixed,
    Token
} from "./41278-h-1-fee-precision-loss-disrupts-liquidations-and-causes-loss.sol";

contract Finding41278Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_borrow_fee_underpays_lps() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.engine().util(), 10, "util");
        assertEq(e.engine().rate(), 6, "rate");
        assertEq(e.engine().paid(), e.BUGGY(), "paid");
        assertEq(e.fairPaid(), e.FAIR(), "fair");
        assertEq(e.shortfall(), e.SHORT(), "short");
        assertEq(e.token().balanceOf(e.lp()), e.BUGGY(), "lp");
        assertEq(e.marker().balanceOf(SINK), e.SHORT(), "marker");
        console2.log("buggy fee");
        console2.log(e.engine().paid());
        console2.log("fair fee");
        console2.log(e.fairPaid());
        console2.log("lp shortfall");
        console2.log(e.shortfall());
    }

    function test_control_full_precision_pays_the_fair_fee() public {
        Token token = new Token();
        FeeEngineFixed fixedEngine = new FeeEngineFixed(address(token), address(this));
        token.mint(address(fixedEngine), 100_000 ether);
        uint256 paid = fixedEngine.charge();
        assertEq(paid, 11281831743780000000000, "fair");
        assertEq(token.balanceOf(address(this)), paid, "receiver");
        assertEq(token.balanceOf(address(fixedEngine)), 100_000 ether - paid, "left");
        assertEq(paid - 9467280000000000000000, 1814551743780000000000, "gap vs buggy");
    }
}
