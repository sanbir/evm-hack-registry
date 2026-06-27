// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;
pragma experimental ABIEncoderV2;

import "./Utils/SafeMath.sol";
import "./Interfaces/EIP20Interface.sol";
import "./PToken/PErc20/PErc20.sol";
import "./Comptroller/ComptrollerInterfaces.sol";
import "./Interfaces/AaveInterfaces.sol";
import "./Interfaces/UniswapV3Interfaces.sol";
import "./PriceOracle/PriceOracleInterfaces.sol";

contract Liquidator is AaveIFlashLoanSimpleReceiver {
    using SafeMath for uint256;
    using SafeMath for int;

    AaveIPoolAddressesProvider public ADDRESSES_PROVIDER;
    AaveIPool public POOL;
    IUniswapV3SwapRouter public SWAP_ROUTER;

    bool internal _notEntered;
    modifier nonReentrant() {
        require(_notEntered, "Liquidator: reentered");
        _notEntered = false;
        _;
        _notEntered = true; // get a gas-refund post-Istanbul
    }

    struct LiquidateParams {
        PErc20 pToken; // TODO PErc20 does not support ETH
        address borrower;
        uint256 repayAmount;
        PErc20 pTokenCollateral; // TODO ^^ PTokenInterface
        address initiator;
        bool collateralAsReward; // true to receive pTokenCollateral as reward; false to receive pToken as reward
    }

    constructor(address AaveAddressesProvider, address UniswapRouter) public {
        ADDRESSES_PROVIDER = AaveIPoolAddressesProvider(AaveAddressesProvider);
        SWAP_ROUTER = IUniswapV3SwapRouter(UniswapRouter);
        POOL = AaveIPool(ADDRESSES_PROVIDER.getPool());
        _notEntered = true;
    }

    /// @notice liquidate 'borrower' loan of 'pToken' using max worth collateral and max possible amount to liquidate; take 'pToken' as reward
    /// 1. Borrow X TokenA from AAVE flashloan
    /// 2. Liquidate TokenA loan and receive Y TokenB
    /// 3. Trade all Y TokenB for Z TokenA on Uniswap (Z > X)
    /// 4. Repay AAVE flashloan for X TokenA
    /// 5. Keep Z - X TokenA as profit
    function liquidate(PErc20 pToken, address borrower, address initiator) external {
        PTokenInterface pTokenCollateral = _findMaxWorthCollateral(pToken, borrower);
        uint256 repayAmount = _findMaxRepayAmount(pToken, borrower, pTokenCollateral);

        return _liquidateImpl(pToken, borrower, repayAmount, pTokenCollateral, initiator, false);
    }

    /// @notice liquidate 'borrower' loan of 'pToken' using 'pTokenCollateral' and max possible amount to liquidate; take 'pTokenCollateral' as reward
    /// 1. Borrow X TokenA from AAVE flashloan
    /// 2. Liquidate TokenA loan and receive Y TokenB
    /// 3. Trade Z TokenB for exact X TokenA on Uniswap (Z < Y)
    /// 4. Repay AAVE flashloan for X TokenA
    /// 5. Keep Y - Z TokenB as profit
    function liquidateFor(PErc20 pToken, address borrower, PTokenInterface pTokenCollateral, address initiator) external {
        uint256 repayAmount = _findMaxRepayAmount(pToken, borrower, pTokenCollateral);

        return _liquidateImpl(pToken, borrower, repayAmount, pTokenCollateral, initiator, true);
    }

    /// @notice liquidate 'borrower' loan of 'pToken' using max worth collateral and max possible amount to liquidate; take collateral as reward
    function liquidateForBest(PErc20 pToken, address borrower, address initiator) external {
        PTokenInterface pTokenCollateral = _findMaxWorthCollateral(pToken, borrower);
        uint256 repayAmount = _findMaxRepayAmount(pToken, borrower, pTokenCollateral);

        return _liquidateImpl(pToken, borrower, repayAmount, pTokenCollateral, initiator, true);
    }

    function _liquidateImpl(PErc20 pToken, address borrower, uint256 repayAmount, PTokenInterface pTokenCollateral, address initiator, bool collateralAsReward) internal {
        require(pToken.isPToken(), "invalid argument");
        bytes memory params = _encodeParams(pToken, borrower, repayAmount, pTokenCollateral, initiator, collateralAsReward);
        uint16 referralCode = 0; // TODO ??

        POOL.flashLoanSimple(address(this), pToken.underlying(), repayAmount, params, referralCode);
    }

    function executeOperation(address asset, uint256 amount, uint256 premium, address flashloanInitiator, bytes calldata params) external nonReentrant returns (bool) {
        // pre-requirements
        uint256 totalDebt = amount.add(premium);
        require(msg.sender == address(POOL), "Liquidator: sender must be the pool"); // this function should only be called by Aave pool after receiving flashloan
        require(_getBalance(address(this), asset) >= amount, "Liquidator: invalid balance");
        require(premium < amount, "Liquidator: fee too high");

        _executeOperationImpl(asset, amount, totalDebt, flashloanInitiator, params);

        // post-requirements
        require(_getBalance(address(this), asset) >= amount, "Liquidator: insufficient balance to payoff debt");
        require(_getBalance(address(this), asset) >= totalDebt, "Liquidator: insufficient balance to payoff fee");

        return true;
    }

    function _executeOperationImpl(address asset, uint256 amount, uint256 totalDebt, address /*flashloanInitiator*/, bytes memory _params) internal {
        // validate params
        LiquidateParams memory params = _decodeParams(_params);
        require(address(params.pToken) != address(params.pTokenCollateral), "Liquidator: not supported");
        require(params.pTokenCollateral.underlying() != address(0), "Liquidator: not supported");
        require(params.pToken.underlying() == asset, "Liquidator: invalid arguments");
        require(amount == params.repayAmount, "Liquidator: invalid arguments");

        // liquidation
        uint256 seizedPTokens = _callLiquidate(params);

        // redeem received PTokens for tokens
        uint256 seizedTokens = _redeemPTokens(params.pTokenCollateral, seizedPTokens);
        uint256 userEarnings = 0;
        address rewardAddress;

        // exchange tokens
        if (params.collateralAsReward) { // params.pTokenCollateral.underlying() as reward
            uint256 soldTokens = _exchangeTokensForExactAmount(params.pTokenCollateral.underlying(), asset, totalDebt, seizedTokens.sub(1));
            userEarnings = seizedTokens.sub(soldTokens);
            rewardAddress = params.pTokenCollateral.underlying();
            require(userEarnings == _getBalance(address(this), rewardAddress), "Liquidator: invalid balance after");

        } else { // asset as reward
            uint256 receivedTokens = _exchangeAllTokens(params.pTokenCollateral.underlying(), asset, totalDebt.add(1));
            userEarnings = receivedTokens.sub(totalDebt);
            rewardAddress = asset;
        }

        // send user earnings
        require(userEarnings > 0, "Liquidator: no actual earnings");
        require(EIP20Interface(rewardAddress).transfer(params.initiator, userEarnings), "Liquidator: send earnings transfer failed");

        // payoff debt
        require(EIP20Interface(asset).approve(address(POOL), totalDebt), "Liquidator: payoff debt approve failed");
    }

    function _encodeParams(PErc20 pToken, address borrower, uint256 repayAmount, PTokenInterface pTokenCollateral, address initiator, bool collateralAsReward) internal pure returns (bytes memory) {
        bytes memory params = abi.encode(address(pToken), borrower, repayAmount, address(pTokenCollateral), initiator, collateralAsReward);
        return params;
    }

    function _decodeParams(bytes memory _params) internal pure returns (LiquidateParams memory) {
        LiquidateParams memory params;
        address pTokenAddress;
        address pTokenCollateralAddress;
        (pTokenAddress, params.borrower, params.repayAmount, pTokenCollateralAddress, params.initiator, params.collateralAsReward) = abi.decode(_params, (address, address, uint256, address, address, bool));
        params.pToken = PErc20(pTokenAddress);
        params.pTokenCollateral = PErc20(pTokenCollateralAddress);
        return params;
    }

    function _findMaxWorthCollateral(PErc20 pToken, address borrower) internal returns (PTokenInterface) {
        ComptrollerNoNFTInterface comptroller = ComptrollerNoNFTInterface(address(pToken.comptroller()));
        PToken[] memory collaterals = comptroller.getAssetsIn(borrower);
        uint256 maxCollateralWorth = 0;
        PTokenInterface result;

        for (uint256 i = 0; i < collaterals.length; i++) {
            uint256 collateralPrice = PriceOracleNoNFTInterface(comptroller.oracle()).getUnderlyingPrice(collaterals[i]);
            uint256 collateralWorth = collateralPrice.mul(collaterals[i].balanceOfUnderlying(borrower));

            // because priceOracle returns number of decimals that depends on underlying asset,
            //   we've got even number of decimals in this comparison:
            if (collateralWorth >= maxCollateralWorth) {
                maxCollateralWorth = collateralWorth;
                result = PTokenInterface(collaterals[i]);
            }
        }

        return result;
    }

    function _findMaxRepayAmount(PErc20 pToken, address borrower, PTokenInterface pTokenCollateral) internal returns (uint256) {
        ComptrollerNoNFTInterface comptroller = ComptrollerNoNFTInterface(address(pToken.comptroller()));
        uint256 collateralPrice = PriceOracleNoNFTInterface(comptroller.oracle()).getUnderlyingPrice(PToken(address(pTokenCollateral)));
        uint256 collateralWorth = collateralPrice.mul(pTokenCollateral.balanceOfUnderlying(borrower));
        uint256 borrowedPrice = PriceOracleNoNFTInterface(comptroller.oracle()).getUnderlyingPrice(pToken);
        uint256 liquidationIncentive = comptroller.liquidationIncentiveMantissa();
        uint256 result = collateralWorth.div(liquidationIncentive.mul(borrowedPrice).div(1e18)); // liquidationIncentive has 18 decimals
        uint256 borrowedAmount = pToken.borrowBalanceStored(borrower);
        uint256 maxResult = borrowedAmount.mul(comptroller.closeFactorMantissa()).div(1e18); // closeFactorMantissa has 18 decimals

        return result > maxResult ? maxResult : result;
    }

    function _getBalance(address account, address asset) internal view returns (uint256) {
        return EIP20Interface(asset).balanceOf(account);
    }

    /// @return seized token amount
    function _callLiquidate(LiquidateParams memory params) internal returns (uint256) {
        // pre-requirements
        (uint256 error, uint256 seizeTokens) = params.pToken.comptroller().liquidateCalculateSeizeTokens(address(params.pToken), address(params.pTokenCollateral), params.repayAmount);
        require(error == 0, "Liquidator: liquidateCalculateSeizeTokens error");

        uint256 protocolSeizeShare = seizeTokens.mul(params.pTokenCollateral.protocolSeizeShareMantissa()).div(1e18); // protocolSeizeShareMantissa has 18 decimals
        seizeTokens = seizeTokens.sub(protocolSeizeShare);

        // liquidation
        require(EIP20Interface(params.pToken.underlying()).approve(address(params.pToken), params.repayAmount), "Liquidator: liquidate approve failed");
        require(params.pToken.liquidateBorrow(params.borrower, params.repayAmount, params.pTokenCollateral) == 0, "Liquidator: liquidateBorrow error");

        // post-requirements
        require(params.pTokenCollateral.balanceOf(address(this)) >= seizeTokens, "Liquidator: invalid balance after liquidation");

        return seizeTokens;
    }

    /// @return tokens redeemed
    function _redeemPTokens(PErc20 pTokenCollateral, uint256 amount) internal returns (uint256) {
        // pre-requirements
        require(pTokenCollateral.balanceOf(address(this)) >= amount, "Liquidator: invalid amount to redeem");

        // redeem everything
        require(pTokenCollateral.redeem(amount) == 0, "Liquidator: redeem error");

        // post-requirements
        uint256 result = _getBalance(address(this), pTokenCollateral.underlying());
        assert(result > 0);

        return result;
    }

    /// @return fee of the best found existing pool for ('assetToSell', 'assetToReceive') pair
    function _findBestPoolFee(address assetToSell, address assetToReceive) internal returns (uint24) {
        IUniswapV3Factory factory = IUniswapV3Factory(SWAP_ROUTER.factory());
        uint24[] memory possibleFees = new uint24[](3);
        possibleFees[0] = 500; possibleFees[1] = 3000; possibleFees[2] = 10000; // lower first

        for (uint256 i = 0; i < possibleFees.length; i++) {
            address poolAddress = factory.getPool(assetToSell, assetToReceive, possibleFees[i]);
            if (poolAddress == address(0)) continue;
            IUniswapV3Pool pool = IUniswapV3Pool(poolAddress);

            (uint160 sqrtPriceX96, , , , , ,) = pool.slot0();
            if (pool.liquidity() > 0 && sqrtPriceX96 > 0) return possibleFees[i];
        }

        revert("Liquidator: no uniswap v3 pool available");
    }

    /// @return amount received
    function _exchangeAllTokens(address assetToSell, address assetToReceive, uint256 minAmountToReceive) internal returns (uint256) {
        // pre-requirements
        uint256 amountToSell = _getBalance(address(this), assetToSell);
        assert(minAmountToReceive > 0);

        IUniswapV3SwapRouter.ExactInputSingleParams memory swapParams;
        swapParams.tokenIn = assetToSell;
        swapParams.tokenOut = assetToReceive;
        swapParams.fee = _findBestPoolFee(assetToSell, assetToReceive);
        swapParams.recipient = address(this);
        swapParams.deadline = block.timestamp;
        swapParams.amountIn = amountToSell;
        swapParams.amountOutMinimum = minAmountToReceive;
        swapParams.sqrtPriceLimitX96 = 0; // 0 to ensure we swap our exact input amount

        require(EIP20Interface(assetToSell).approve(address(SWAP_ROUTER), amountToSell), "Liquidator: exchange tokens approve failed");
        uint256 amountOut = SWAP_ROUTER.exactInputSingle(swapParams);

        // post-requirements
        assert(amountOut >= minAmountToReceive);
        assert(_getBalance(address(this), assetToReceive) >= minAmountToReceive);

        return amountOut;
    }

    /// @return amount sold
    function _exchangeTokensForExactAmount(address assetToSell, address assetToReceive, uint256 amountToReceive, uint256 amountInMaximum) internal returns (uint256) {
        // pre-requirements
        assert(amountToReceive > 0);

        IUniswapV3SwapRouter.ExactOutputSingleParams memory swapParams;
        swapParams.tokenIn = assetToSell;
        swapParams.tokenOut = assetToReceive;
        swapParams.fee = _findBestPoolFee(assetToSell, assetToReceive);
        swapParams.recipient = address(this);
        swapParams.deadline = block.timestamp;
        swapParams.amountOut = amountToReceive;
        swapParams.amountInMaximum = amountInMaximum;
        swapParams.sqrtPriceLimitX96 = 0; // 0 to ensure we swap our exact input amount

        require(EIP20Interface(assetToSell).approve(address(SWAP_ROUTER), amountInMaximum), "Liquidator: exchange tokens approve failed");
        uint256 amountIn = SWAP_ROUTER.exactOutputSingle(swapParams);

        // post-requirements
        assert(amountIn <= amountInMaximum);
        assert(_getBalance(address(this), assetToReceive) >= amountToReceive);

        return amountIn;
    }
}
