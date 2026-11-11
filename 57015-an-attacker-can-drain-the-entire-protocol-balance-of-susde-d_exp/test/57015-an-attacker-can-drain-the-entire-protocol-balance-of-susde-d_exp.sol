// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    SUSDe,
    PVault,
    YVault
} from "./57015-an-attacker-can-drain-the-entire-protocol-balance-of-susde-d.sol";

/// @dev Auditor fix: subtract only the base assets. The sUSDe transfer still includes yield.
contract PVaultFixed is PVault {
    constructor(SUSDe s) PVault(s) {}

    function _redeemYield(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        uint256 assetsPlusYield = assets + previewYield(caller, shares);
        uint256 sUSDeAssets = susde.previewWithdraw(assetsPlusYield);
        _settle(caller, receiver, owner, assets, sUSDeAssets, shares);
    }
}

contract Finding57015Test is Test {
    function test_exploit_takes_the_whole_susde_balance() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.susde().balanceOf(address(e)), 10, "attacker received 10");
        assertEq(e.susde().balanceOf(address(e.p())), 0, "vault has 0");
        assertEq(e.p().depositedBase(), 0, "base consumed");
    }

    function test_control_pays_only_the_caller_share() public {
        SUSDe susde = new SUSDe();
        PVaultFixed p = new PVaultFixed(susde);
        YVault y = new YVault(p);
        p.setYVault(address(y));

        p.deposit(5);
        p.deposit(5);
        y.deposit(5);
        p.startYieldPhase();
        susde.donate(5);
        for (uint256 i = 0; i < 5; i++) {
            y.redeem(1, address(this));
        }

        assertEq(susde.balanceOf(address(this)), 7, "caller receives 7, not 10");
        assertEq(susde.balanceOf(address(p)), 3, "the other depositor's shares stay");
        assertEq(p.depositedBase(), 5, "base falls only by principal");
    }
}
