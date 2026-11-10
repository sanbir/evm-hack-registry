// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, System} from "./38333-usds-stability-can-be-compromised-as-collateral-deposited-to.sol";

contract Finding38333Test is Test {
    uint256 internal constant GAMMA = 1000 ether;
    uint256 internal constant DEBT = 1800 ether;
    // 1000e18 * 10000 / 11000 at the post-crash $1 price.
    uint256 internal constant MAX_MINT_AT_CRASH = 909090909090909090909;

    function test_liquidation_leaves_gamma_collateral() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.collateralAtCrash(), GAMMA, "gamma collateral usd");
        assertEq(e.maxMintableAtCrash(), MAX_MINT_AT_CRASH, "max mintable");
        assertTrue(e.wasLiquidatable(), "position was underwater");
        assertGt(e.DEBT(), e.maxMintableAtCrash(), "debt above the cap");
        assertEq(e.seizedShares(), 0, "protocol seized no gamma shares");
        assertEq(e.sharesLeftOnVault(), GAMMA, "1000e18 shares were not liquidated");
        assertEq(e.borrowerWeth(), GAMMA, "borrower recovered the collateral");
        assertEq(e.borrowerUsds(), DEBT, "borrower kept 1800e18 USDs");
        console2.log("gamma collateral usd", e.collateralAtCrash());
        console2.log("max mintable at crash", e.maxMintableAtCrash());
        console2.log("debt", e.DEBT());
        console2.log("shares seized", e.seizedShares());
        console2.log("shares left on vault", e.sharesLeftOnVault());
        console2.log("borrower WETH", e.borrowerWeth());
        console2.log("borrower USDs", e.borrowerUsds());
    }

    function test_control_counts_gamma_collateral() public {
        System s = new System(address(this));
        s.weth().mint(address(this), GAMMA);
        s.weth().transfer(address(s.vault()), GAMMA);
        s.vault().depositYield(bytes32("WETH"), 0);
        s.vault().mint(address(this), DEBT);
        s.router().setPrice(1 ether);

        assertEq(s.vault().collateralUsd(), GAMMA, "control sees the same collateral");
        assertTrue(s.vault().undercollateralised(), "control is underwater");
        assertEq(s.vault().maxMintableUsd(), MAX_MINT_AT_CRASH, "same cap");

        s.router().liquidateVaultCountingYield();

        assertEq(s.hyp().balanceOf(address(s.sink())), GAMMA, "protocol seized 1000e18 shares");
        assertEq(s.hyp().balanceOf(address(s.vault())), 0, "vault gamma position is gone");
        assertEq(s.weth().balanceOf(address(this)), 0, "borrower did not keep the collateral");
        assertEq(s.vault().minted(), 0, "debt wiped in both paths");
        assertTrue(s.vault().liquidated(), "liquidation ran");
        console2.log("control seized shares", s.hyp().balanceOf(address(s.sink())));
        console2.log("control vault shares", s.hyp().balanceOf(address(s.vault())));
        console2.log("control borrower WETH", s.weth().balanceOf(address(this)));
    }
}
