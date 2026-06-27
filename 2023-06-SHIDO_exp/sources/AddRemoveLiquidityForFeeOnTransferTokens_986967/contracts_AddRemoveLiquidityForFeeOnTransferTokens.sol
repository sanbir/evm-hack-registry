// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./IBabyDogeRouter.sol";
import "./IBabyDogeFactory.sol";
import "./IBabyDogePair.sol";
import "./IWETH.sol";

// @title Contract is designed to add and remove liquidity for token pairs which contain taxed token
contract AddRemoveLiquidityForFeeOnTransferTokens {
    IBabyDogeRouter immutable public router;
    IBabyDogeFactory immutable public factory;
    address immutable public WETH;

    // user account => lp token address => amount of LP tokens received
    mapping(address => mapping(address => uint256)) public lpReceived;

    event LiquidityAdded (
        address indexed account,
        address indexed tokenA,
        address indexed tokenB,
        uint256 amountA,
        uint256 amountB,
        uint256 lpAmount
    );

    event LiquidityRemoved (
        address indexed account,
        address indexed tokenA,
        address indexed tokenB,
        uint256 amountA,
        uint256 amountB,
        uint256 lpAmount
    );

    /*
     * @param _router Baby Doge router address
     */
    constructor(
        IBabyDogeRouter _router
    ){
        router = _router;
        factory = IBabyDogeFactory(_router.factory());
        WETH = _router.WETH();
    }

    receive() external payable {}

    /*
     * @param tokenA First token address
     * @param tokenB Second token address
     * @param amountADesired Amount of tokenA that user wants to add to liquidity
     * @param amountBDesired Amount of tokenB that user wants to add to liquidity
     * @param amountAMin Minimum amount of tokenA that must be added to liquidity
     * @param amountBMin Minimum amount of tokenB that must be added to liquidity
     * @param to Account address that should receive LP tokens
     * @param deadline Timestamp, until when this transaction must be executed
     * @return amountA Amount of tokenA added to liquidity
     * @return amountB Amount of tokenB added to liquidity
     * @return liquidity Amount of liquidity received
     */
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
    external
    returns (
        uint256 amountA,
        uint256 amountB,
        uint256 liquidity
    ) {
        IERC20(tokenA).transferFrom(msg.sender, address(this), amountADesired);
        IERC20(tokenB).transferFrom(msg.sender, address(this), amountBDesired);
        _approveIfRequired(tokenA, amountADesired);
        _approveIfRequired(tokenB, amountBDesired);

        (amountA, amountB, liquidity) = router.addLiquidity(
            tokenA,
            tokenB,
            amountADesired,
            amountBDesired,
            amountAMin,
            amountBMin,
            to,
            deadline
        );

        address lpToken = factory.getPair(tokenA, tokenB);
        lpReceived[msg.sender][lpToken] += liquidity;

        uint256 remainingAmountA = IERC20(tokenA).balanceOf(address(this));
        if (remainingAmountA > 0) {
            IERC20(tokenA).transfer(msg.sender, remainingAmountA);
        }

        uint256 remainingAmountB = IERC20(tokenB).balanceOf(address(this));
        if (remainingAmountB > 0) {
            IERC20(tokenB).transfer(msg.sender, remainingAmountB);
        }

        emit LiquidityAdded(
            msg.sender,
            tokenA,
            tokenB,
            amountA,
            amountB,
            liquidity
        );
    }


    /*
     * @param token ERC20 token address to add to liqidity
     * @param amountTokenDesired Amount of ERC20 token that user wants to add to liquidity
     * @param amountTokenMin Minimum amount of ERC20 token that must be added to liquidity
     * @param amountETHMin Minimum amount of BNB that must be added to liquidity
     * @param to Account address that should receive LP tokens
     * @param deadline Timestamp, until when this transaction must be executed
     * @return amountToken Amount of ERC20 token added to liquidity
     * @return amountETH Amount of BNB added to liquidity
     * @return liquidity Amount of liquidity received
     */
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address payable to,
        uint256 deadline
    )
    external
    payable
    returns (
        uint256 amountToken,
        uint256 amountETH,
        uint256 liquidity
    ) {
        IERC20(token).transferFrom(msg.sender, address(this), amountTokenDesired);
        _approveIfRequired(token, amountTokenDesired);

        (amountToken, amountETH, liquidity) = router.addLiquidityETH{value : msg.value}(
            token,
            amountTokenDesired,
            amountTokenMin,
            amountETHMin,
            to,
            deadline
        );

        address lpToken = factory.getPair(token, WETH);
        lpReceived[msg.sender][lpToken] += liquidity;

        uint256 remainingTokens = IERC20(token).balanceOf(address(this));
        if (remainingTokens > 0) {
            IERC20(token).transfer(msg.sender, remainingTokens);
        }

        uint256 bnbBalance = address(this).balance;
        if (bnbBalance > 0) {
            (bool success,) = payable(msg.sender).call{value : bnbBalance}("");
            require(success, "BNB return failed");
        }

        emit LiquidityAdded(
            msg.sender,
            token,
            WETH,
            amountToken,
            amountETH,
            liquidity
        );
    }


    /*
     * @param tokenA First token address
     * @param tokenB Second token address
     * @param liquidity Amount of LP tokens that should be transferred
     * @param amountAMin Minimum amount of tokenA that must be returned
     * @param amountBMin Minimum amount of tokenB that must be returned
     * @param to Account address that should receive tokens
     * @param deadline Timestamp, until when this transaction must be executed
     * @return amountA Amount of tokenA received
     * @return amountB Amount of tokenB received
     * @dev Liquidity can be removed only by address which added liquidity with this smart contract
     * @dev Liquidity amount must not be greater than amount, received with this smart contract
     */
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) public returns (uint256 amountA, uint256 amountB) {
        address lpToken = factory.getPair(tokenA, tokenB);
        IERC20(lpToken).transferFrom(msg.sender, address(this), liquidity);
        _approveIfRequired(lpToken, liquidity);

        require(liquidity <= lpReceived[msg.sender][lpToken], "Over received amount");
        lpReceived[msg.sender][lpToken] -= liquidity;

        (amountA, amountB) = router.removeLiquidity(
            tokenA,
            tokenB,
            liquidity,
            amountAMin,
            amountBMin,
            address(this),
            deadline
        );

        IERC20(tokenA).transfer(to, IERC20(tokenA).balanceOf(address(this)));
        IERC20(tokenB).transfer(to, IERC20(tokenB).balanceOf(address(this)));

        emit LiquidityRemoved(
            msg.sender,
            tokenA,
            tokenB,
            amountA,
            amountB,
            liquidity
        );
    }


    /*
     * @param token ERC20 token address
     * @param liquidity Amount of LP tokens that should be transferred
     * @param amountTokenMin Minimum amount of ERC20 token that must be returned
     * @param amountETHMin Minimum amount of BNB that must be returned
     * @param to Account address that should receive tokens/BNB
     * @param deadline Timestamp, until when this transaction must be executed
     * @return amountToken Amount of ERC20 token received
     * @return amountETH Amount of BNB received
     * @dev Liquidity can be removed only by address which added liquidity with this smart contract
     * @dev Liquidity amount must not be greater than amount, received with this smart contract
     */
    function removeLiquidityETH(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address payable to,
        uint256 deadline
    ) public returns (uint256 amountToken, uint256 amountETH) {
        address lpToken = factory.getPair(token, WETH);
        IERC20(lpToken).transferFrom(msg.sender, address(this), liquidity);
        _approveIfRequired(lpToken, liquidity);

        require(liquidity <= lpReceived[msg.sender][lpToken], "Over received amount");
        lpReceived[msg.sender][lpToken] -= liquidity;

        (amountToken, amountETH) = router.removeLiquidity(
            token,
            WETH,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this),
            deadline
        );

        IWETH(WETH).withdraw(amountETH);
        (bool success,) = to.call{value : amountETH}("");
        require(success, "BNB transfer failed");

        IERC20(token).transfer(to, IERC20(token).balanceOf(address(this)));

        emit LiquidityRemoved(
            msg.sender,
            token,
            WETH,
            amountToken,
            amountETH,
            liquidity
        );
    }


    /*
     * @param tokenA First token address
     * @param tokenB Second token address
     * @param liquidity Amount of LP tokens that should be transferred
     * @param amountAMin Minimum amount of tokenA that must be returned
     * @param amountBMin Minimum amount of tokenB that must be returned
     * @param to Account address that should receive tokens
     * @param deadline Timestamp, until when this transaction must be executed
     * @param approveMax Was max uint amount approved for transfer?
     * @param v Signature v part
     * @param r Signature r part
     * @param s Signature s part
     * @return amountA Amount of tokenA received
     * @return amountB Amount of tokenB received
     * @dev Liquidity can be removed only by address which added liquidity with this smart contract
     * @dev Liquidity amount must not be greater than amount, received with this smart contract
     */
    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountA, uint256 amountB) {
        address pair = factory.getPair(tokenA, tokenB);
        uint256 value = approveMax ? type(uint256).max : liquidity;
        IBabyDogePair(pair).permit(
            msg.sender,
            address(this),
            value,
            deadline,
            v,
            r,
            s
        );
        (amountA, amountB) = removeLiquidity(
            tokenA,
            tokenB,
            liquidity,
            amountAMin,
            amountBMin,
            to,
            deadline
        );
    }


    /*
     * @param token ERC20 token address
     * @param liquidity Amount of LP tokens that should be transferred
     * @param amountTokenMin Minimum amount of ERC20 token that must be returned
     * @param amountETHMin Minimum amount of BNB that must be returned
     * @param to Account address that should receive tokens/BNB
     * @param deadline Timestamp, until when this transaction must be executed
     * @param approveMax Was max uint amount approved for transfer?
     * @param v Signature v part
     * @param r Signature r part
     * @param s Signature s part
     * @return amountToken Amount of ERC20 token received
     * @return amountETH Amount of BNB received
     * @dev Liquidity can be removed only by address which added liquidity with this smart contract
     * @dev Liquidity amount must not be greater than amount, received with this smart contract
     */
    function removeLiquidityETHWithPermit(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountToken, uint256 amountETH) {
        address pair = factory.getPair(token, WETH);
        uint256 value = approveMax ? type(uint256).max : liquidity;
        IBabyDogePair(pair).permit(
            msg.sender,
            address(this),
            value,
            deadline,
            v,
            r,
            s
        );
        (amountToken, amountETH) = removeLiquidityETH(
            token,
            liquidity,
            amountTokenMin,
            amountETHMin,
            payable(to),
            deadline
        );
    }


    /*
     * @notice Approves token to router if required
     * @param token ERC20 token
     * @param minAmount Minimum amount of tokens to spend
     */
    function _approveIfRequired(
        address token,
        uint256 minAmount
    ) private {
        if (IERC20(token).allowance(address(this), address(router)) < minAmount) {
            IERC20(token).approve(address(router), type(uint256).max);
        }
    }
}
