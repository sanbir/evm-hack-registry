// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./38066-deliveryplacesettleasktaker-has-incorrect-access-control-cod.sol";

contract SettleAskTakerAccessControlTest is Test {
    /// @notice HARM: run() proves the rightful stock authority is denied service while the
    ///         offer's original authority (a different role) is wrongly authorized instead.
    function test_exploit_wrongAuthorityAuthorized_rightfulOwnerBlocked() public {
        Exploit e = new Exploit();
        e.run();

        (, StockStatus finalStatus,,,) = e.deliveryPlace().stockInfoMap(e.stockAddr());
        assertEq(uint8(finalStatus), uint8(StockStatus.Finished), "settlement should have finalized under the wrong caller");
    }

    /// @notice Isolates the exact call that reverts: the rightful stock authority alone,
    ///         calling settleAskTaker on their own settlement stock, is blocked.
    function test_rightfulStockAuthority_isBlocked() public {
        MockToken tok = new MockToken();
        TokenManager tm = new TokenManager();
        DeliveryPlace dp = new DeliveryPlace(tm);
        Actor stockOwner = new Actor();
        Actor offerOwner = new Actor();

        address stock = address(0x1001);
        address offer = address(0x2002);
        dp.setup(stock, offer, address(stockOwner), address(offerOwner), 500, address(tok), 1e16);
        tok.mint(address(stockOwner), 500 * 1e16);
        stockOwner.approveToken(tok, address(tm), type(uint256).max);

        bool ok = stockOwner.trySettle(dp, stock, 500);
        assertFalse(ok, "stock authority should have been blocked by the buggy check");
    }

    /// @notice Control: when the stock authority and the offer authority happen to be the
    ///         SAME address, the check passes — isolating that the bug is specifically
    ///         "checks the wrong field", not "settleAskTaker is always broken".
    function test_control_sameAddressBothRoles_succeeds() public {
        MockToken tok = new MockToken();
        TokenManager tm = new TokenManager();
        DeliveryPlace dp = new DeliveryPlace(tm);
        Actor sameActor = new Actor();

        address stock = address(0x3003);
        address offer = address(0x4004);
        dp.setup(stock, offer, address(sameActor), address(sameActor), 100, address(tok), 1e16);
        tok.mint(address(sameActor), 100 * 1e16);
        sameActor.approveToken(tok, address(tm), type(uint256).max);

        bool ok = sameActor.trySettle(dp, stock, 100);
        assertTrue(ok, "same-address case should succeed (isolates the wrong-field bug)");
    }
}
