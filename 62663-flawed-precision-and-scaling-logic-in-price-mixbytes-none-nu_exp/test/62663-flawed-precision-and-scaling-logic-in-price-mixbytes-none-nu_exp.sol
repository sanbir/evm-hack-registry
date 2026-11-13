// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    IFeed,
    MockFeed,
    Lender,
    Stable
} from "./62663-flawed-precision-and-scaling-logic-in-price-mixbytes-none-nu.sol";

/// Control: the uniform fixed-point fold from the report. Each inverted feed
/// contributes SCALING * 10**feed.decimals() / feedPrice, then the accumulator
/// is divided by SCALING, and 18-decimal conversion happens once at the end.
contract FixedOracle {
    function price() public pure returns (uint256) {
        uint256 scaling = 1e36;
        uint256 hp = scaling;
        uint256 feedPrice = 2e8;
        uint256 feedDec = 8;
        for (uint256 i = 0; i < 2; i++) {
            uint256 rate = scaling * (10 ** feedDec) / feedPrice;
            hp = hp * rate / scaling;
        }
        return hp * 1e18 / scaling;
    }
}

contract FixedLender {
    FixedOracle public oracle;
    Stable public stable;

    constructor(FixedOracle _oracle, Stable _stable) {
        oracle = _oracle;
        stable = _stable;
    }

    function borrow(uint256 collateralAmount) external returns (uint256 minted) {
        uint256 px = oracle.price();
        minted = collateralAmount * px / 1e18;
        stable.mint(msg.sender, minted);
    }
}

contract Finding62663Test is Test {
    function test_exploit_borrow_is_1e18_times_too_big() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.stable().balanceOf(address(e)), e.BUGGY_BORROW(), "buggy mint");
        assertEq(e.BUGGY_BORROW() / e.FAIR_BORROW(), 1e18, "factor");
    }

    function test_control_fixed_scale_borrows_fair_amount() public {
        FixedOracle oracle = new FixedOracle();
        Stable stable = new Stable();
        FixedLender lender = new FixedLender(oracle, stable);
        uint256 minted = lender.borrow(1e18);
        assertEq(oracle.price(), 25e16, "fair price 0.25e18");
        assertEq(minted, 25e16, "fair borrow");
        assertEq(stable.balanceOf(address(this)), 25e16, "control paid the fair amount");

        Exploit buggy = new Exploit();
        assertEq(buggy.oracle().price() / oracle.price(), 1e18, "buggy price / fair price");
    }
}
