// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {Exploit, USDCToken, Pool} from "./41859-h-01-loss-of-fees-due-to-rounding-down-pashov-audit-group-no.sol";

/// Recommended SCALE_FACTOR of 1e18. Same fee and liquidity pay the LP in full.
contract FixedKeeper {
    uint256 public constant SCALE_FACTOR = 1e18;
    USDCToken public usdc;
    address public pool;
    uint256 public liquidity = 2e18;
    uint256 public acc;

    constructor(USDCToken _usdc, address _pool) {
        usdc = _usdc;
        pool = _pool;
    }

    function collectAndClaim(uint256 amount0, address lp) external returns (uint256 paid) {
        usdc.transferFrom(pool, address(this), amount0);
        acc = (amount0 * SCALE_FACTOR) / liquidity;
        paid = liquidity * acc / SCALE_FACTOR;
        usdc.transfer(lp, paid);
    }
}

contract Finding41859Test is Test {
    function test_exploit_one_usdc_fee_accrues_as_zero() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.accrual(), 0, "acc");
        assertEq(e.claimed(), 0, "claim");
        assertEq(e.stuck(), 1_000_000, "stuck");
        assertEq(e.shortfall(), 1_000_000, "shortfall");
        assertEq(e.profit(), 1_000_000, "profit");

        console.log("fee collected", uint256(1_000_000));
        console.log("liquidity", uint256(2e18));
        console.log("accFeePerShare delta", e.accrual());
        console.log("LP claim", e.claimed());
        console.log("shortfall", e.shortfall());
    }

    function test_control_scale_1e18_pays_the_lp_the_full_usdc() public {
        USDCToken usdc = new USDCToken();
        Pool pool = new Pool();
        FixedKeeper fixedKeeper = new FixedKeeper(usdc, address(pool));
        usdc.mint(address(pool), 1_000_000);
        pool.approve(usdc, address(fixedKeeper), 1_000_000);

        uint256 paid = fixedKeeper.collectAndClaim(1_000_000, address(this));

        assertEq(fixedKeeper.acc(), 500_000, "scaled acc");
        assertEq(paid, 1_000_000, "LP not paid");
        assertEq(usdc.balanceOf(address(fixedKeeper)), 0, "dust stuck");
        assertEq(usdc.balanceOf(address(this)), 1_000_000, "receiver");
        console.log("control acc", fixedKeeper.acc());
        console.log("control paid", paid);
    }
}
