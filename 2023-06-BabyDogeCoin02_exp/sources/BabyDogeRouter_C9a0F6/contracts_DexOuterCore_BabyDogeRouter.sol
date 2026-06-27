pragma solidity =0.6.6;

import "./interfaces/IBabyDogeFactory.sol";
import "./libraries/TransferHelper.sol";
import "./interfaces/IBabyDogeRouter.sol";
import "./libraries/BabyDogeLibrary.sol";
import "./libraries/SafeMath.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IWETH.sol";

contract BabyDogeRouter is IBabyDogeRouter {
    using SafeMath for uint256;

    address public immutable override factory;
    address public immutable override WETH;
    address internal immutable babyDogeToken;
    address internal feeSetter;
    uint256[] internal values;
    uint256[] internal fee;
    mapping(address => uint256) internal specialOffer;
    mapping(address => bool) internal whiteListed;
    bool internal requireWhitelist;
    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp);
        _;
    }

    modifier onlyWhitelisted() {
        if (requireWhitelist) require(whiteListed[msg.sender] == true);
        _;
    }

    /*
     * Params
     * address - What is factory address?
     * address - What is WETH token address?
     * address - What is Baby Doge Token address?
     * uint256[] memory - List of Doge Token balance values, that should correspond list of fees
     * uint256[] memory - List of trade fees, will be applied to users according to their balances
     **** example **** If [0, 500000, 1000000] are list of balance values
     **** example **** and [997000, 998000, 1000000] are list of corresponding fees
     **** example **** Then user with 400000 Baby Doge Tokens will have 9970 fee level
     **** example **** and user with 1000000 Baby Doge Tokens will have 10000 fee level (0% fee)
     *
     * Function creates new contract with addresses of factory, WETH and Baby Doge Token
     * Function sets deploying address as a Fee Setter, who will be able to set fees
     */
    constructor(
        address _factory,
        address _WETH,
        address _babyDogeToken,
        uint256[] memory _values,
        uint256[] memory _fee
    ) public {
        factory = _factory;
        WETH = _WETH;
        babyDogeToken = _babyDogeToken;
        feeSetter = msg.sender;
        setTradeFee(_values, _fee);
    }

    /*
     * Params
     * address - Who do you want to become Fee Setter?
     *
     * Function sets new Fee Setter
     * Only current Fee Setter can use it
     */

    function setFeeSetter(address _feeSetter) external {
        require(msg.sender == feeSetter);
        feeSetter = _feeSetter;
    }

    /*
     * Params
     * address - Who is allowed to interact with the exchange?
     */

    function whitelistAddress(address _address, bool _whitelistStatus)
        external
    {
        require(msg.sender == feeSetter);
        whiteListed[_address] = _whitelistStatus;
    }

    /*
     * Params
     * address - Who is allowed to interact with the exchange?
     */

    function setWhitelistRequire(bool _require) external {
        require(msg.sender == feeSetter);
        requireWhitelist = _require;
    }

    /*
     * Params
     * uint256[] memory - List of Doge Token balance values, that should correspond list of fees
     * uint256[] memory - List of fees, will be applied to users according to their balances
     *
     * Function sets new trade fees and corresponding balance values
     */

    function setTradeFee(uint256[] memory _values, uint256[] memory _fee)
        public
    {
        require(msg.sender == feeSetter);
        require(_values.length == _fee.length);
        for(uint i = 0; i < _values.length; i++) {
            require(_fee[i] <= 1_000_000);
        }

        values = _values;
        fee = _fee;
    }

    /*
     * Params
     * address - What's the address of token pair you want set special fee for?
     * uint256 - What's the amount of special fee you want to set for this pair?
     *
     * Function sets special fee for token pair
     * This will be the smallest fee for this token pair
     */

    function setPairFee(address _lpAddress, uint256 _fee) external {
        require(msg.sender == feeSetter);
        specialOffer[_lpAddress] = _fee;
    }

    receive() external payable {
        assert(msg.sender == WETH); // only accept ETH via fallback from the WETH contract
    }

    // **** ADD LIQUIDITY ****
    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) internal virtual returns (uint256 amountA, uint256 amountB) {
        // create the pair if it doesn"t exist yet
        if (IBabyDogeFactory(factory).getPair(tokenA, tokenB) == address(0)) {
            IBabyDogeFactory(factory).createPair(tokenA, tokenB);
        }
        (uint256 reserveA, uint256 reserveB) = BabyDogeLibrary.getReserves(
            factory,
            tokenA,
            tokenB
        );
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint256 amountBOptimal = BabyDogeLibrary.quote(
                amountADesired,
                reserveA,
                reserveB
            );
            if (amountBOptimal <= amountBDesired) {
                require(amountBOptimal >= amountBMin);
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint256 amountAOptimal = BabyDogeLibrary.quote(
                    amountBDesired,
                    reserveB,
                    reserveA
                );
                assert(amountAOptimal <= amountADesired);
                require(amountAOptimal >= amountAMin);
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }

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
        virtual
        override
        ensure(deadline)
        onlyWhitelisted
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        )
    {
        (amountA, amountB) = _addLiquidity(
            tokenA,
            tokenB,
            amountADesired,
            amountBDesired,
            amountAMin,
            amountBMin
        );
        address pair = BabyDogeLibrary.pairFor(factory, tokenA, tokenB);
        TransferHelper.safeTransferFrom(tokenA, msg.sender, pair, amountA);
        TransferHelper.safeTransferFrom(tokenB, msg.sender, pair, amountB);
        liquidity = IBabyDogePair(pair).mint(to);
    }

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    )
        external
        payable
        virtual
        override
        ensure(deadline)
        onlyWhitelisted
        returns (
            uint256 amountToken,
            uint256 amountETH,
            uint256 liquidity
        )
    {
        (amountToken, amountETH) = _addLiquidity(
            token,
            WETH,
            amountTokenDesired,
            msg.value,
            amountTokenMin,
            amountETHMin
        );
        address pair = BabyDogeLibrary.pairFor(factory, token, WETH);
        TransferHelper.safeTransferFrom(token, msg.sender, pair, amountToken);
        IWETH(WETH).deposit{value: amountETH}();
        assert(IWETH(WETH).transfer(pair, amountETH));
        liquidity = IBabyDogePair(pair).mint(to);
        // refund dust eth, if any
        if (msg.value > amountETH)
            TransferHelper.safeTransferETH(msg.sender, msg.value - amountETH);
    }

    // **** REMOVE LIQUIDITY ****
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        public
        virtual
        override
        ensure(deadline)
        onlyWhitelisted
        returns (uint256 amountA, uint256 amountB)
    {
        address pair = BabyDogeLibrary.pairFor(factory, tokenA, tokenB);
        IBabyDogePair(pair).transferFrom(msg.sender, pair, liquidity); // send liquidity to pair
        (uint256 amount0, uint256 amount1) = IBabyDogePair(pair).burn(to);
        (address token0, ) = BabyDogeLibrary.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0
            ? (amount0, amount1)
            : (amount1, amount0);
        require(amountA >= amountAMin);
        require(amountB >= amountBMin);
    }

    function removeLiquidityETH(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    )
        public
        virtual
        override
        ensure(deadline)
        returns (uint256 amountToken, uint256 amountETH)
    {
        (amountToken, amountETH) = removeLiquidity(
            token,
            WETH,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this),
            deadline
        );
        TransferHelper.safeTransfer(token, to, amountToken);
        IWETH(WETH).withdraw(amountETH);
        TransferHelper.safeTransferETH(to, amountETH);
    }

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
    ) external virtual override returns (uint256 amountA, uint256 amountB) {
        address pair = BabyDogeLibrary.pairFor(factory, tokenA, tokenB);
        uint256 value = approveMax ? uint256(-1) : liquidity;
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
    )
        external
        virtual
        override
        returns (uint256 amountToken, uint256 amountETH)
    {
        address pair = BabyDogeLibrary.pairFor(factory, token, WETH);
        uint256 value = approveMax ? uint256(-1) : liquidity;
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
            to,
            deadline
        );
    }

    // **** REMOVE LIQUIDITY (supporting fee-on-transfer tokens) ****
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) public virtual override ensure(deadline) returns (uint256 amountETH) {
        (, amountETH) = removeLiquidity(
            token,
            WETH,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this),
            deadline
        );
        TransferHelper.safeTransfer(
            token,
            to,
            IERC20(token).balanceOf(address(this))
        );
        IWETH(WETH).withdraw(amountETH);
        TransferHelper.safeTransferETH(to, amountETH);
    }

    function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
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
    ) external virtual override returns (uint256 amountETH) {
        address pair = BabyDogeLibrary.pairFor(factory, token, WETH);
        uint256 value = approveMax ? uint256(-1) : liquidity;
        IBabyDogePair(pair).permit(
            msg.sender,
            address(this),
            value,
            deadline,
            v,
            r,
            s
        );
        amountETH = removeLiquidityETHSupportingFeeOnTransferTokens(
            token,
            liquidity,
            amountTokenMin,
            amountETHMin,
            to,
            deadline
        );
    }

    // **** SWAP ****
    // requires the initial amount to have already been sent to the first pair
    function _swap(
        uint256[] memory amounts,
        address[] memory path,
        address _to
    ) internal virtual {
        for (uint256 i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0, ) = BabyDogeLibrary.sortTokens(input, output);
            uint256 amountOut = amounts[i + 1];
            (uint256 amount0Out, uint256 amount1Out) = input == token0
                ? (uint256(0), amountOut)
                : (amountOut, uint256(0));
            address to = i < path.length - 2
                ? BabyDogeLibrary.pairFor(factory, output, path[i + 2])
                : _to;
            IBabyDogePair(BabyDogeLibrary.pairFor(factory, input, output))
                .swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    )
        external
        virtual
        override
        ensure(deadline)
        onlyWhitelisted
        returns (uint256[] memory amounts)
    {
        amounts = BabyDogeLibrary.getAmountsOut(
            factory,
            amountIn,
            path,
            address(this)
        );
        require(amounts[amounts.length - 1] >= amountOutMin);
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            BabyDogeLibrary.pairFor(factory, path[0], path[1]),
            amounts[0]
        );
        _swap(amounts, path, to);
    }

    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    )
        external
        virtual
        override
        ensure(deadline)
        onlyWhitelisted
        returns (uint256[] memory amounts)
    {
        amounts = BabyDogeLibrary.getAmountsIn(
            factory,
            amountOut,
            path,
            address(this)
        );
        require(amounts[0] <= amountInMax);
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            BabyDogeLibrary.pairFor(factory, path[0], path[1]),
            amounts[0]
        );
        _swap(amounts, path, to);
    }

    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    )
        external
        payable
        virtual
        override
        ensure(deadline)
        onlyWhitelisted
        returns (uint256[] memory amounts)
    {
        require(path[0] == WETH);
        amounts = BabyDogeLibrary.getAmountsOut(
            factory,
            msg.value,
            path,
            address(this)
        );
        require(amounts[amounts.length - 1] >= amountOutMin);
        IWETH(WETH).deposit{value: amounts[0]}();
        assert(
            IWETH(WETH).transfer(
                BabyDogeLibrary.pairFor(factory, path[0], path[1]),
                amounts[0]
            )
        );
        _swap(amounts, path, to);
    }

    function swapTokensForExactETH(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    )
        external
        virtual
        override
        ensure(deadline)
        onlyWhitelisted
        returns (uint256[] memory amounts)
    {
        require(path[path.length - 1] == WETH);
        amounts = BabyDogeLibrary.getAmountsIn(
            factory,
            amountOut,
            path,
            address(this)
        );
        require(amounts[0] <= amountInMax);
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            BabyDogeLibrary.pairFor(factory, path[0], path[1]),
            amounts[0]
        );
        _swap(amounts, path, address(this));
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    )
        external
        virtual
        override
        ensure(deadline)
        onlyWhitelisted
        returns (uint256[] memory amounts)
    {
        require(path[path.length - 1] == WETH);
        amounts = BabyDogeLibrary.getAmountsOut(
            factory,
            amountIn,
            path,
            address(this)
        );
        require(amounts[amounts.length - 1] >= amountOutMin);
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            BabyDogeLibrary.pairFor(factory, path[0], path[1]),
            amounts[0]
        );
        _swap(amounts, path, address(this));
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }

    function swapETHForExactTokens(
        uint256 amountOut,
        address[] calldata path,
        address to,
        uint256 deadline
    )
        external
        payable
        virtual
        override
        ensure(deadline)
        onlyWhitelisted
        returns (uint256[] memory amounts)
    {
        require(path[0] == WETH);
        amounts = BabyDogeLibrary.getAmountsIn(
            factory,
            amountOut,
            path,
            address(this)
        );
        require(amounts[0] <= msg.value);
        IWETH(WETH).deposit{value: amounts[0]}();
        assert(
            IWETH(WETH).transfer(
                BabyDogeLibrary.pairFor(factory, path[0], path[1]),
                amounts[0]
            )
        );
        _swap(amounts, path, to);
        // refund dust eth, if any
        if (msg.value > amounts[0])
            TransferHelper.safeTransferETH(msg.sender, msg.value - amounts[0]);
    }

    // **** SWAP (supporting fee-on-transfer tokens) ****
    // requires the initial amount to have already been sent to the first pair
    function _swapSupportingFeeOnTransferTokens(
        address[] memory path,
        address _to
    ) internal virtual {
        for (uint256 i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0, ) = BabyDogeLibrary.sortTokens(input, output);
            IBabyDogePair pair = IBabyDogePair(
                BabyDogeLibrary.pairFor(factory, input, output)
            );
            uint256 amountInput;
            uint256 amountOutput;
            {
                // scope to avoid stack too deep errors
                (uint256 reserve0, uint256 reserve1, ) = pair.getReserves();
                (uint256 reserveInput, uint256 reserveOutput) = input == token0
                    ? (reserve0, reserve1)
                    : (reserve1, reserve0);
                amountInput = IERC20(input).balanceOf(address(pair)).sub(
                    reserveInput
                );
                uint256 swapFee = transactionFee(path[i], path[i + 1], msg.sender);
                amountOutput = BabyDogeLibrary.getAmountOut(
                    amountInput,
                    reserveInput,
                    reserveOutput,
                    swapFee
                );
            }
            (uint256 amount0Out, uint256 amount1Out) = input == token0
                ? (uint256(0), amountOutput)
                : (amountOutput, uint256(0));
            address to = i < path.length - 2
                ? BabyDogeLibrary.pairFor(factory, output, path[i + 2])
                : _to;
            pair.swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual override ensure(deadline) onlyWhitelisted {
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            BabyDogeLibrary.pairFor(factory, path[0], path[1]),
            amountIn
        );
        uint256 balanceBefore = IERC20(path[path.length - 1]).balanceOf(to);
        _swapSupportingFeeOnTransferTokens(path, to);
        require(
            IERC20(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >=
                amountOutMin
        );
    }

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable virtual override ensure(deadline) onlyWhitelisted {
        require(path[0] == WETH);
        uint256 amountIn = msg.value;
        IWETH(WETH).deposit{value: amountIn}();
        assert(
            IWETH(WETH).transfer(
                BabyDogeLibrary.pairFor(factory, path[0], path[1]),
                amountIn
            )
        );
        uint256 balanceBefore = IERC20(path[path.length - 1]).balanceOf(to);
        _swapSupportingFeeOnTransferTokens(path, to);
        require(
            IERC20(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >=
                amountOutMin
        );
    }

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual override ensure(deadline) onlyWhitelisted {
        require(path[path.length - 1] == WETH);
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            BabyDogeLibrary.pairFor(factory, path[0], path[1]),
            amountIn
        );
        _swapSupportingFeeOnTransferTokens(path, address(this));
        uint256 amountOut = IERC20(WETH).balanceOf(address(this));
        require(amountOut >= amountOutMin);
        IWETH(WETH).withdraw(amountOut);
        TransferHelper.safeTransferETH(to, amountOut);
    }

    // **** LIBRARY FUNCTIONS ****
    function quote(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) public pure virtual override returns (uint256 amountB) {
        return BabyDogeLibrary.quote(amountA, reserveA, reserveB);
    }

    /*
     * Params
     * uint256 - What is amount of input tokens to you want to swap?
     * uint256 - What is reserve of input tokens for chosen pair?
     * uint256 - What is reserve of output tokens for chosen pair?
     * uint256 - What is fee for current transaction?
     *
     * Returns the minimum input asset amount required to buy the given output asset amount (accounting for fees) given reserves
     */

    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 swapFee
    ) public pure virtual returns (uint256 amountOut) {
        return
            BabyDogeLibrary.getAmountOut(
                amountIn,
                reserveIn,
                reserveOut,
                swapFee
            );
    }

    /*
     * Params
     * uint256 - How much of output tokens do you want to receive?
     * uint256 - What is reserve of input tokens for chosen pair?
     * uint256 - What is reserve of output tokens for chosen pair?
     * uint256 - What is fee for current transaction?
     *
     * Returns the minimum input asset amount required to buy the given output asset amount (accounting for fees) given reserves.
     */

    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 swapFee
    ) public pure virtual returns (uint256 amountIn) {
        return
            BabyDogeLibrary.getAmountIn(
                amountOut,
                reserveIn,
                reserveOut,
                swapFee
            );
    }

    function getAmountsOut(uint256 amountIn, address[] memory path)
        public
        view
        virtual
        override
        returns (uint256[] memory amounts)
    {
        return
            BabyDogeLibrary.getAmountsOut(
                factory,
                amountIn,
                path,
                address(this)
            );
    }

    function getAmountsIn(uint256 amountOut, address[] memory path)
        public
        view
        virtual
        override
        returns (uint256[] memory amounts)
    {
        return
            BabyDogeLibrary.getAmountsIn(
                factory,
                amountOut,
                path,
                address(this)
            );
    }

    /*
     * Params
     * address - What's the address of the token you want to send?
     * address - What's the address of the token you want to receive?
     * address - Should be equal to the address of the caller.
     *           Exception is our library, where it set to `msg.sender` on purpose.
     *
     * Calculates fee for this token pair
     * Checks if the particular LP has a special fee
     * Checks balance of Baby Doge Token. If balance is entitled to discount, discounts
     */

    function transactionFee(
        address _tokenIn, 
        address _tokenOut,
        address _msgSender
    )
        public
        view
        override
        returns (uint256)
    {
        uint256 fees;
        address lpToken = BabyDogeLibrary.pairFor(
            factory,
            _tokenIn,
            _tokenOut
        );
        if (specialOffer[lpToken] != 0) {
            fees = specialOffer[lpToken];
        }

        uint256 tokenBalance = IERC20(babyDogeToken).balanceOf(_msgSender);
        for (uint256 i; i < values.length; ) {
            if (tokenBalance >= values[i]) {
                if (fee[i] > fees) fees = fee[i];
            }
            i++;
        }
        return fees;
    }
}
