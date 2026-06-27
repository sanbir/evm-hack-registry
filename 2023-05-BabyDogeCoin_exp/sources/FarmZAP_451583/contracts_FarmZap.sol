// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./BBD/interfaces/IWETH.sol";
import "./BBD/interfaces/IBabyDogeRouter.sol";
import "./BBD/interfaces/IBabyDogeFactory.sol";
import "./BBD/interfaces/IBabyDogePair.sol";
import "./IFarm.sol";

contract FarmZAP {
    struct TokensAddresses {
        address tokenIn;
        address token0;
        address token1;
        address lpToken;
    }

    struct LpData {
        address token0;
        address token1;
        uint256 reserveA;
        uint256 reserveB;
        uint256 totalSupply;
    }

    // remaining tokens after adding liquidity won't be returned
    // to users account if amount is below this threshold
    uint256 private constant THRESHOLD = 1e12;

    IWETH public immutable WBNB;
    IBabyDogeRouter public immutable router;
    IBabyDogeFactory public immutable factory;

    event LpBought (
        address account,
        address tokenIn,
        address lpToken,
        uint256 amountIn,
        uint256 amountOut,
        uint256 returnedAmount
    );

    event LpBoughtAndDeposited (
        address farm,
        address account,
        address tokenIn,
        address lpToken,
        uint256 amountIn,
        uint256 amountOut,
        uint256 returnedAmount
    );

    event TokensBoughtAndDeposited (
        address farm,
        address account,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );


    /*
     * @param _router Baby doge router address
     */
    constructor(
        IBabyDogeRouter _router
    ) {
        router = _router;
        WBNB = IWETH(_router.WETH());
        factory = IBabyDogeFactory(_router.factory());
    }

    // to receive BNB
    receive() payable external {}

    /*
     * @notice Swaps input token to LP token and returns remaining amount of tokens, swapped back to input token. Public function
     * @param amountIn Amount of input tokens
     * @param amountOutMin Minimum amount of LP tokens to receive
     * @param path0 Address path to swap to token0
     * @param path1 Address path to swap to token1
     * @return Received LP amount. Use for callStatic
     * @dev Last element of path0 must be token0. Last element of path1 must be token1
     * @dev If input token is token0, leave path0 empty
     * @dev If input token is token1, leave path1 empty
     * @dev First element of path0 and path1 must be input token (if not empty)
     * @dev Should be used for front end estimation with static call after input tokens approval
     */
    function buyLpTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path0,
        address[] calldata path1
    ) external payable returns(uint256) {
        (
            uint256 lpAmount,
            TokensAddresses memory tokens,
            uint256 returnedAmount
        ) = _buyLpTokens(
            amountIn,
            amountOutMin,
            path0,
            path1
        );

        IERC20(tokens.lpToken).transfer(msg.sender, lpAmount);

        emit LpBought (
            msg.sender,
            tokens.tokenIn,
            tokens.lpToken,
            amountIn,
            lpAmount,
            returnedAmount
        );

        return(lpAmount);
    }


    /*
     * @notice Swaps input token to LP token and deposits on behalf of msg.sender to specific farm
     * @param farm Farm address, where LP tokens should be deposited
     * @param amountIn Amount of input tokens
     * @param amountOutMin Minimum amount of LP tokens to receive
     * @param path0 Address path to swap to token0
     * @param path1 Address path to swap to token1
     * @return Received LP amount. Use for callStatic
     * @dev Last element of path0 must be token0. Last element of path1 must be token1
     * @dev If input token is token0, leave path0 empty
     * @dev If input token is token1, leave path1 empty
     * @dev First element of path0 and path1 must be input token (if not empty)
     * @dev Should be used for front end estimation with static call after input tokens approval
     */
    function buyLpTokensAndDepositOnBehalf(
        IFarm farm,
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path0,
        address[] calldata path1
    ) external payable returns(uint256) {
        (
            uint256 lpAmount,
            TokensAddresses memory tokens,
            uint256 returnedAmount
        ) = _buyLpTokens(
            amountIn,
            amountOutMin,
            path0,
            path1
        );
        require(tokens.lpToken == farm.stakeToken(), "Not a stake token");

        _approveIfRequired(tokens.lpToken, address(farm), lpAmount);
        farm.depositOnBehalf(lpAmount, msg.sender);

        emit LpBoughtAndDeposited (
            address(farm),
            msg.sender,
            tokens.tokenIn,
            tokens.lpToken,
            amountIn,
            lpAmount,
            returnedAmount
        );

        return(lpAmount);
    }


    /*
     * @notice Swaps input token to ERC20 token and deposits on behalf of msg.sender to specified farm
     * @param farm Farm address, where tokens should be deposited
     * @param amountIn Amount of input tokens
     * @param amountOutMin Minimum amount of tokens to receive
     * @param path Address path to swap input token
     * @return Received token amount
     * @dev Last element of path must be stake token
     * @dev First element of path must be input token
     */
    function buyTokensAndDepositOnBehalf(
        IFarm farm,
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path
    ) external payable returns(uint256) {
        if (msg.value > 0) {
            require(address(WBNB) == path[0], "Input token != WBNB");
            require(amountIn == msg.value, "Invalid msg.value");
            WBNB.deposit{value: amountIn}();
        } else {
            IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        }
        address tokenOut = path[path.length - 1];
        require(tokenOut == farm.stakeToken(), "Not a stake token");

        _approveIfRequired(path[0], address(router), amountIn);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn,
            amountOutMin,
            path,
            address(this),
            block.timestamp + 1200
        );
        uint256 received = IERC20(tokenOut).balanceOf(address(this));

        _approveIfRequired(tokenOut, address(farm), received);
        farm.depositOnBehalf(received, msg.sender);

        emit TokensBoughtAndDeposited (
            address(farm),
            msg.sender,
            path[0],
            tokenOut,
            amountIn,
            received
        );

        return received;
    }


    /*
     * @notice Estimates amount of Lp tokens based on input amount
     * @param amountIn Amount of input tokens
     * @param path0 Address path to swap to token0
     * @param path1 Address path to swap to token1
     * @dev Should be used for front end estimation before input tokens approval
     */
    function estimateAmountOfLpTokens(
        uint256 amountIn,
        address[] calldata path0,
        address[] calldata path1
    ) external view returns(uint256 lpAmount){
        LpData memory lpData = _getLpData(path0, path1);
        if (lpData.totalSupply == 0) {
            return 0;
        }
        uint256 amountIn0 = amountIn/2;
        uint256 amountIn1 = amountIn/2;

        uint256 amount0 = _getAmountOut(amountIn0, path0);
        uint256 amount1 = _getAmountOut(amountIn1, path1);

        lpAmount = _estimateLpAmount(
            amount0,
            amount1,
            lpData
        );
    }


    /*
     * @notice Swaps input token to LP token. Internal function
     * @param amountIn Amount of input tokens
     * @param amountOutMin Minimum amount of LP tokens to receive
     * @param path0 Address path to swap to token0
     * @param path1 Address path to swap to token1
     * @return lpAmount Amount of LP tokens received
     * @return tokens Addresses of input token, token0, token1, lpToken and WBNB
     * @return returnedAmount amount of input tokens returned to user
     */
    function _buyLpTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path0,
        address[] calldata path1
    ) internal returns (
        uint256 lpAmount,
        TokensAddresses memory tokens,
        uint256 returnedAmount
    ) {
        tokens = _checkBeforeGettingLp(amountIn, path0, path1);

        (uint256 amount0, uint256 amount1) = _swapInputToTokens(
            path0,
            path1
        );

        uint256 _lpAmount = _addLiquidity(
            tokens,
            amount0,
            amount1
        );
        require(_lpAmount >= amountOutMin, "Below amountOutMin");

        // return remaining tokens
        returnedAmount = _returnTokens(tokens, path0, path1);

        return (_lpAmount, tokens, returnedAmount);
    }


    /*
     * @notice Transfers input token to the contract and checks if paths are correct
     * @param amountIn Amount of input tokens
     * @param path0 Address path to swap to token0
     * @param path1 Address path to swap to token1
     * @return Addresses of input token, token0, token1, lpToken and WBNB
     */
    function _checkBeforeGettingLp(
        uint256 amountIn,
        address[] calldata path0,
        address[] calldata path1
    ) private returns(TokensAddresses memory) {
        address tokenIn;
        if (path0.length > 0) {
            tokenIn = path0[0];
        } else {
            tokenIn = path1[0];
        }

        if (msg.value > 0) {
            require(
                (path0.length == 0 || path0[0] == address(WBNB))
                && (path1.length == 0 || path1[0] == address(WBNB)),
                "Input token != WBNB"
            );
            require(amountIn == msg.value, "Invalid msg.value");
            WBNB.deposit{value: msg.value}();
        } else {
            IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        }

        require(
            (path0.length == 0 || path0.length >= 2)
            && (path1.length == 0 || path1.length >= 2),
            "Invalid path"
        );
        require(
            path0.length == 0 || path1.length == 0 || path0[0] == path1[0],
            "Invalid input token"
        );
        address token0 = path0.length > 0 ? path0[path0.length - 1] : path1[0];
        address token1 = path1.length > 0 ? path1[path1.length - 1] : path0[0];
        require(token0 != token1, "Same tokens");

        address lpAddress = factory.getPair(token0, token1);
        require(lpAddress != address(0), "Pair doesn't exist");
        {
            (uint112 reserve0, uint112 reserve1,) = IBabyDogePair(lpAddress).getReserves();
            require(reserve0 > 0 && reserve1 > 0, "Empty reserves");
        }

        return TokensAddresses({
            tokenIn: tokenIn,
            token0: token0,
            token1: token1,
            lpToken: lpAddress
        });
    }


    /*
     * @notice Adds liquidity, then balances remaining token to liquidity again
     * @param tokens Addresses of input token, token0, token1, lpToken and WBNB
     * @param amount0 Amount of token0 to add to liquidity
     * @param amount1 Amount of token1 to add to liquidity
     * @return liquidity Amount of LP tokens received
     */
    function _addLiquidity(
        TokensAddresses memory tokens,
        uint256 amount0,
        uint256 amount1
    ) private returns(uint256 liquidity) {
        _approveIfRequired(tokens.token0, address(router), amount0);
        _approveIfRequired(tokens.token1, address(router), amount1);

        (uint256 amountA, uint256 amountB,) = router.addLiquidity(
            tokens.token0,
            tokens.token1,
            amount0,
            amount1,
            0,
            0,
            address(this),
            block.timestamp + 1200
        );

        uint256 reserve0 = IERC20(tokens.token0).balanceOf(tokens.lpToken);
        uint256 reserve1 = IERC20(tokens.token1).balanceOf(tokens.lpToken);

        uint256 remaining;
        if (amount0 > amountA) {
            remaining = amount0 - amountA;
            uint256 amountIn = _getPerfectAmountIn(remaining, reserve0);
            amount0 = remaining - amountIn;

            address[] memory path = new address[](2);
            path[0] = tokens.token0;
            path[1] = tokens.token1;
            _approveIfRequired(tokens.token0, address(router), amountIn);
            router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                amountIn,
                0,
                path,
                address(this),
                block.timestamp + 1200
            );
            amount1 = IERC20(tokens.token1).balanceOf(address(this));
        } else {
            remaining = amount1 - amountB;
            uint256 amountIn = _getPerfectAmountIn(remaining, reserve1);
            amount1 = remaining - amountIn;

            address[] memory path = new address[](2);
            path[0] = tokens.token1;
            path[1] = tokens.token0;
            _approveIfRequired(tokens.token1, address(router), amountIn);
            router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                amountIn,
                0,
                path,
                address(this),
                block.timestamp + 1200
            );
            amount0 = IERC20(tokens.token0).balanceOf(address(this));
        }

        // add to liquidity remaining tokens after splitting amounts in perfect ratio
        router.addLiquidity(
            tokens.token0,
            tokens.token1,
            amount0,
            amount1,
            0,
            0,
            address(this),
            block.timestamp + 1200
        );

        liquidity = IERC20(tokens.lpToken).balanceOf(address(this));
    }


    /*
     * @notice Swaps input token to LP token
     * @param path0 Address path to swap to token0
     * @param path1 Address path to swap to token1
     * @return amount0 - Received amount of token0
     * @return amount1 - Received amount of token1
     * @dev Internal function without checks
     */
    function _swapInputToTokens(
        address[] calldata path0,
        address[] calldata path1
    ) internal returns (uint256 amount0, uint256 amount1) {
        uint256 amountIn = path0.length > 0
            ? IERC20(path0[0]).balanceOf(address(this))
            : IERC20(path1[0]).balanceOf(address(this));
        amount0 = amountIn / 2;
        amount1 = amountIn / 2;

        if (path0.length > 0) {
            _approveIfRequired(path0[0], address(router), amount0);
            router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                amount0,
                0,
                path0,
                address(this),
                block.timestamp + 1200
            );

            amount0 = IERC20(path0[path0.length - 1]).balanceOf(address(this));
        }

        if (path1.length > 0) {
            _approveIfRequired(path1[0], address(router), amount1);
            router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                amount1,
                0,
                path1,
                address(this),
                block.timestamp + 1200
            );

            amount1 = IERC20(path1[path1.length - 1]).balanceOf(address(this));
        }
    }


    /*
     * @notice Transfers remaining tokens back to user. Converts them back to input token
     * @param tokens Addresses of input token, token0, token1, lpToken and WBNB
     * @param path0 Swap path for token0
     * @param path1 Swap path for token1
     * @return toReturn Returned amount of input tokens
     * @dev Transfers tokens only above THRESHOLD value to save gas
     */
    function _returnTokens(
        TokensAddresses memory tokens,
        address[] calldata path0,
        address[] calldata path1
    ) private returns(uint256 toReturn) {
        uint256 remainingAmount0 = IERC20(tokens.token0).balanceOf(address(this));
        uint256 remainingAmount1 = IERC20(tokens.token1).balanceOf(address(this));

        if (remainingAmount0 > THRESHOLD && path0.length > 0) {
            address[] memory path = _reversePath(path0);
            _approveIfRequired(path[0], address(router), remainingAmount0);
            router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                remainingAmount0,
                0,
                path,
                address(this),
                block.timestamp + 1200
            );
        }

        if (remainingAmount1 > THRESHOLD && path1.length > 0) {
            address[] memory path = _reversePath(path1);
            _approveIfRequired(path[0], address(router), remainingAmount1);
            router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                remainingAmount1,
                0,
                path,
                address(this),
                block.timestamp + 1200
            );
        }

        toReturn = IERC20(tokens.tokenIn).balanceOf(address(this));
        if (toReturn > 0) {
            if (msg.value > 0) {
                _approveIfRequired(address(WBNB), address(WBNB), toReturn);
                WBNB.withdraw(toReturn);
                (bool success, ) = payable(msg.sender).call{value: toReturn}("");
                require(success, "Can't return BNB");
            } else {
                IERC20(tokens.tokenIn).transfer(msg.sender, toReturn);
            }
        }
    }


    /*
     * @notice Reverses address array
     * @param path Input path
     * @return Reversed path
     */
    function _reversePath(
        address[] calldata path
    ) private pure returns(address[] memory) {
        uint256 arrayLength = path.length;
        address[] memory reversedPath = new address[](arrayLength);

        for (uint i = 0; i < arrayLength; i++) {
            reversedPath[i] = path[arrayLength - 1 - i];
        }

        return reversedPath;
    }


    /*
     * @notice Approves token to router if required
     * @param token ERC20 token
     * @param spender Spender contract address
     * @param minAmount Minimum amount of tokens to spend
     */
    function _approveIfRequired(
        address token,
        address spender,
        uint256 minAmount
    ) private {
        if (IERC20(token).allowance(address(this), spender) < minAmount) {
            IERC20(token).approve(spender, type(uint256).max);
        }
    }


    /*
     * @notice Calculates amountIn in such way, so that remaining tokens would be split into
     * such amounts, that most of them would be added to liquidity
     * @param remaining Remaining amount of tokenA to be split between tokenA and tokenB and added to liquidity
     * @param reserveIn Current reserve of tokenA
     * @return Amount of tokenA to be swapped to tokenB in order to achieve perfect liquidity ratio
     * @dev Used for adding to liquidity remaining tokens instead of returning them to the user
     */
    function _getPerfectAmountIn(
        uint256 remaining,
        uint256 reserveIn
    ) private pure returns(uint256) {
        return Math.sqrt((3988009 * reserveIn + 3988000 * remaining)
        / 3976036 * reserveIn)
        - 1997 * reserveIn / 1994;
    }


    /****************************** Estimation functions helpers ******************************/
    /*
     * @notice Gets reserves and total supply of LP token
     * @param path0 Address path to swap to token0
     * @param path1 Address path to swap to token1
     * @return lpData Reserves and total supply of LP token
     * @dev Internal function for estimateAmountOfLpTokens
     */
    function _getLpData(
        address[] calldata path0,
        address[] calldata path1
    ) private view returns(LpData memory lpData) {
        address token0 = path0.length > 0 ? path0[path0.length - 1] : path1[0];
        address token1 = path1.length > 0 ? path1[path1.length - 1] : path0[0];
        address pairAddress = factory.getPair(token0, token1);
        if (pairAddress == address(0)) {
            return lpData;
        }

        lpData.token0 = token0;
        lpData.token1 = token1;
        lpData.reserveA = IERC20(token0).balanceOf(pairAddress);
        lpData.reserveB = IERC20(token1).balanceOf(pairAddress);
        lpData.totalSupply = IBabyDogePair(pairAddress).totalSupply();

        return lpData;
    }


    /*
     * @notice Calculate expected amount out of swap
     * @param amountIn Amount ot tokens to pe spent
     * @param path Address path to swap to token0
     * @return amountOut Expected amount of token0
     * @dev Internal function for estimateAmountOfLpTokens
     */
    function _getAmountOut(
        uint256 amountIn,
        address[] calldata path
    ) private view returns(uint256 amountOut) {
        if (path.length > 0) {
            (uint256[] memory amounts) = router.getAmountsOut(amountIn, path);
            amountOut = amounts[amounts.length - 1];
        } else {
            amountOut = amountIn;
        }
    }


    /*
     * @notice Estimates amount of minted LP tokens based on input amounts
     * @param amountADesired Amount of tokens A to add to liquidity
     * @param amountBDesired Amount of tokens B to add to liquidity
     * @param lpData Reserves and total supply of LP token
     * @return liquidity Amount of LP tokens expected to receive in return
     * @dev Internal function for estimateAmountOfLpTokens
     */
    function _estimateLpAmount(
        uint256 amountADesired,
        uint256 amountBDesired,
        LpData memory lpData
    ) private pure returns(uint256 liquidity) {
        uint256 amountBOptimal = amountADesired * lpData.reserveB / lpData.reserveA;

        uint256 amountA;
        uint256 amountB;
        if (amountBOptimal <= amountBDesired) {
            (amountA, amountB) = (amountADesired, amountBOptimal);
        } else {
            uint256 amountAOptimal = amountBDesired * lpData.reserveA / lpData.reserveB;
            (amountA, amountB) = (amountAOptimal, amountBDesired);
        }

        liquidity = Math.min(
            amountA * lpData.totalSupply / lpData.reserveA,
            amountB * lpData.totalSupply / lpData.reserveB
        );
    }
}
