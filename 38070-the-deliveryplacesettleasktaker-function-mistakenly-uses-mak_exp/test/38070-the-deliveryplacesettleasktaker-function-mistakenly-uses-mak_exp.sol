// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./38070-the-deliveryplacesettleasktaker-function-mistakenly-uses-mak.sol";

contract SettleAskTakerWrongTokenTest is Test {
    /// @notice HARM: run() proves the buyer's PointToken credit is booked against
    ///         the maker's unrelated collateral token instead of the actual point
    ///         token that was delivered.
    function test_exploit_creditBookedUnderWrongToken() public {
        Exploit e = new Exploit();
        e.run();

        uint256 correctTokenCredit = e.tokenManager().userTokenBalanceMap(
            e.buyer(), address(e.pointToken()), uint8(TokenManager.TokenBalanceType.PointToken)
        );
        uint256 wrongTokenCredit = e.tokenManager().userTokenBalanceMap(
            e.buyer(), address(e.makerToken()), uint8(TokenManager.TokenBalanceType.PointToken)
        );

        assertEq(correctTokenCredit, 0, "correct-token credit should be zero");
        assertEq(wrongTokenCredit, e.TOKEN_PER_POINT() * e.SETTLED_POINTS(), "wrong-token credit should hold the full amount");
    }

    /// @notice Control: when the maker's collateral token happens to BE the same
    ///         address as the actual point token, the credit lands in the right
    ///         place — isolating that the bug is specifically "wrong token
    ///         address", not "settleAskTaker never credits correctly".
    function test_control_sameTokenAddress_creditsCorrectly() public {
        MockToken tok = new MockToken();
        TokenManager tm = new TokenManager();
        DeliveryPlace dp = new DeliveryPlace(tm);

        address offer = address(0x1003);
        address buyer = address(0x2004);
        dp.setup(offer, buyer, address(tok), address(tok), 1e16);

        tok.mint(address(this), 1000 * 1e16);
        tok.approve(address(tm), type(uint256).max);

        dp.settleAskTaker(offer, 1000);

        uint256 credit = tm.userTokenBalanceMap(buyer, address(tok), uint8(TokenManager.TokenBalanceType.PointToken));
        assertEq(credit, 1000 * 1e16, "same-address case should credit correctly (isolates the wrong-token bug)");
    }
}
