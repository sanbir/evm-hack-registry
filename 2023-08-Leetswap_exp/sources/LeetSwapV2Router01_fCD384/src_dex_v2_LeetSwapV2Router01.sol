// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.17;

import "./interfaces/ILeetSwapV2Factory.sol";
import "./interfaces/ILeetSwapV2Pair.sol";
import "./interfaces/ILeetSwapV2Router01.sol";
import "@leetswap/interfaces/ILiquidityManageable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract LeetSwapV2Router01 is Ownable, ILeetSwapV2Router01 {
    struct Route {
        address from;
        address to;
        bool stable;
    }

    address public immutable factory;
    IWCANTO public immutable wcanto;

    uint256 internal constant MINIMUM_LIQUIDITY = 10**3;
    bytes32 immutable pairCodeHash;
    mapping(address => bool) public stablePairs;
    mapping(address => bool) public isLiquidityManageableWhitelisted;
    bool public deadlineEnabled;
    bool public liquidityManageableEnabled;
    bool public liquidityManageableWhitelistEnabled;

    error InvalidToken();
    error TransferFailed();
    error TradeExpired();
    error InsufficientOutputAmount();
    error InvalidPath();
    error InvalidAmount();
    error CantoTransferFailed();
    error IdenticalAddresses();
    error InsufficientAmount();
    error InsufficientAAmount();
    error InsufficientBAmount();
    error InsufficientLiquidity();
    error ZeroAddress();
    error DeadlineExpired();
    error ArrayLengthMismatch();
    error Unauthorized();

    modifier ensure(uint256 deadline) {
        if (deadlineEnabled && deadline < block.timestamp)
            revert DeadlineExpired();
        _;
    }

    constructor(address _factory, address _wcanto) {
        factory = _factory;
        pairCodeHash = ILeetSwapV2Factory(_factory).pairCodeHash();
        wcanto = IWCANTO(_wcanto);
        liquidityManageableEnabled = true;
        liquidityManageableWhitelistEnabled = true;
    }

    receive() external payable {
        assert(msg.sender == address(wcanto)); // only accept ETH via fallback from the wcanto contract
    }

    // **** LIQUIDITY MANAGEABLE PROTOCOL ****
    //
    // we use the following functions because we can't use modifiers due to the stack size limit
    // and the hefty amount of parameters and local variables of the Uniswap liquidity functions

    // it's safe to naively call the functions because if any of the token don't implement the interface
    // or if the router is not a liquidity manager, the call will silently fail with no harm
    function _startLiquidityManagement(address tokenA, address tokenB)
        internal
    {
        if (!liquidityManageableEnabled) return;

        if (
            !liquidityManageableWhitelistEnabled ||
            isLiquidityManageableWhitelisted[tokenA]
        ) {
            ILiquidityManageable lmTokenA = ILiquidityManageable(tokenA);
            try lmTokenA.isLiquidityManager(address(this)) returns (
                bool isLiquidityManager
            ) {
                if (isLiquidityManager)
                    lmTokenA.setLiquidityManagementPhase(true);
            } catch {}
        }

        if (
            !liquidityManageableWhitelistEnabled ||
            isLiquidityManageableWhitelisted[tokenB]
        ) {
            ILiquidityManageable lmTokenB = ILiquidityManageable(tokenB);
            try lmTokenB.isLiquidityManager(address(this)) returns (
                bool isLiquidityManager
            ) {
                if (isLiquidityManager)
                    lmTokenB.setLiquidityManagementPhase(true);
            } catch {}
        }
    }

    // if the previous 'startPhase' call failed because the router is not a LM, nothing will happen here,
    // still silently fail, whereas if it succeeded, the liquidity management phase will be set to false
    function _stopLiquidityManagement(address tokenA, address tokenB) internal {
        if (!liquidityManageableEnabled) return;

        if (
            !liquidityManageableWhitelistEnabled ||
            isLiquidityManageableWhitelisted[tokenA]
        ) {
            ILiquidityManageable lmTokenA = ILiquidityManageable(tokenA);
            try lmTokenA.isLiquidityManager(address(this)) returns (
                bool isLiquidityManager
            ) {
                if (isLiquidityManager)
                    lmTokenA.setLiquidityManagementPhase(false);
            } catch {}
        }

        if (
            !liquidityManageableWhitelistEnabled ||
            isLiquidityManageableWhitelisted[tokenB]
        ) {
            ILiquidityManageable lmTokenB = ILiquidityManageable(tokenB);
            try lmTokenB.isLiquidityManager(address(this)) returns (
                bool isLiquidityManager
            ) {
                if (isLiquidityManager)
                    lmTokenB.setLiquidityManagementPhase(false);
            } catch {}
        }
    }

    // UniswapV2 compatibility
    function WETH() external view returns (address) {
        return address(wcanto);
    }

    function sortTokens(address tokenA, address tokenB)
        public
        pure
        returns (address token0, address token1)
    {
        if (tokenA == tokenB) revert IdenticalAddresses();
        (token0, token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);
        if (token0 == address(0)) revert ZeroAddress();
    }

    function _pairFor(
        address tokenA,
        address tokenB,
        bool stable
    ) internal view returns (address pair) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        pair = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            factory,
                            keccak256(abi.encodePacked(token0, token1, stable)),
                            pairCodeHash // init code hash
                        )
                    )
                )
            )
        );
    }

    // calculates the CREATE2 address for a pair without making any external calls
    function pairFor(address tokenA, address tokenB)
        public
        view
        returns (address pair)
    {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        bool isStable = stablePairs[_pairFor(token0, token1, true)];
        pair = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            factory,
                            keccak256(
                                abi.encodePacked(token0, token1, isStable)
                            ),
                            pairCodeHash // init code hash
                        )
                    )
                )
            )
        );
    }

    // fetches and sorts the reserves for a pair
    function getReserves(address tokenA, address tokenB)
        public
        view
        returns (uint256 reserveA, uint256 reserveB)
    {
        (address token0, ) = sortTokens(tokenA, tokenB);
        (uint256 reserve0, uint256 reserve1, ) = ILeetSwapV2Pair(
            pairFor(tokenA, tokenB)
        ).getReserves();
        (reserveA, reserveB) = tokenA == token0
            ? (reserve0, reserve1)
            : (reserve1, reserve0);
    }

    // performs chained getAmountOut calculations on any number of pairs
    function getAmountOut(
        uint256 amountIn,
        address tokenIn,
        address tokenOut
    ) public view returns (uint256 amount) {
        address pair = pairFor(tokenIn, tokenOut);
        if (ILeetSwapV2Factory(factory).isPair(pair)) {
            amount = ILeetSwapV2Pair(pair).getAmountOut(amountIn, tokenIn);
        }
    }

    // performs chained getAmountOut calculations on any number of pairs
    function getAmountsOut(uint256 amountIn, Route[] memory routes)
        public
        view
        returns (uint256[] memory amounts)
    {
        if (routes.length < 1) revert InvalidPath();
        amounts = new uint256[](routes.length + 1);
        amounts[0] = amountIn;
        for (uint256 i = 0; i < routes.length; i++) {
            address pair = pairFor(routes[i].from, routes[i].to);
            if (ILeetSwapV2Factory(factory).isPair(pair)) {
                amounts[i + 1] = ILeetSwapV2Pair(pair).getAmountOut(
                    amounts[i],
                    routes[i].from
                );
            }
        }
    }

    // UniswapV2 compatibility
    function getAmountsOut(uint256 amountIn, address[] calldata path)
        public
        view
        returns (uint256[] memory amounts)
    {
        if (path.length < 2) revert InvalidPath();
        Route[] memory routes = _pathToRoutes(path);
        amounts = getAmountsOut(amountIn, routes);
    }

    // given some amount of an asset and pair reserves, returns an equivalent amount of the other asset
    function quoteLiquidity(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) internal pure returns (uint256 amountB) {
        if (amountA <= 0) revert InsufficientAmount();
        if (reserveA <= 0 || reserveB <= 0) revert InsufficientLiquidity();
        amountB = (amountA * reserveB) / reserveA;
    }

    function isPair(address pair) public view returns (bool) {
        return ILeetSwapV2Factory(factory).isPair(pair);
    }

    function _pathToRoutes(address[] calldata path)
        internal
        view
        returns (Route[] memory routes)
    {
        routes = new Route[](path.length - 1);
        for (uint256 i = 0; i < path.length - 1; i++) {
            bool isStable = stablePairs[pairFor(path[i], path[i + 1])];
            routes[i] = Route(path[i], path[i + 1], isStable);
        }
    }

    // **** SWAP ****
    // requires the initial amount to have already been sent to the first pair
    function _swap(
        uint256[] memory amounts,
        Route[] memory routes,
        address _to
    ) internal virtual {
        for (uint256 i = 0; i < routes.length; i++) {
            (address token0, ) = sortTokens(routes[i].from, routes[i].to);
            uint256 amountOut = amounts[i + 1];
            (uint256 amount0Out, uint256 amount1Out) = routes[i].from == token0
                ? (uint256(0), amountOut)
                : (amountOut, uint256(0));
            address to = i < routes.length - 1
                ? pairFor(routes[i + 1].from, routes[i + 1].to)
                : _to;
            ILeetSwapV2Pair(pairFor(routes[i].from, routes[i].to)).swap(
                amount0Out,
                amount1Out,
                to,
                new bytes(0)
            );
        }
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        Route[] memory routes = _pathToRoutes(path);
        amounts = getAmountsOut(amountIn, routes);
        if (amounts[amounts.length - 1] < amountOutMin) {
            revert InsufficientOutputAmount();
        }
        _safeTransferFrom(
            routes[0].from,
            msg.sender,
            pairFor(routes[0].from, routes[0].to),
            amounts[0]
        );
        _swap(amounts, routes, to);
    }

    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable ensure(deadline) returns (uint256[] memory amounts) {
        if (path[0] != address(wcanto)) revert InvalidPath();
        Route[] memory routes = _pathToRoutes(path);
        amounts = getAmountsOut(msg.value, routes);
        if (amounts[amounts.length - 1] < amountOutMin) {
            revert InsufficientOutputAmount();
        }
        wcanto.deposit{value: amounts[0]}();
        assert(
            wcanto.transfer(pairFor(routes[0].from, routes[0].to), amounts[0])
        );
        _swap(amounts, routes, to);
    }

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        if (path[path.length - 1] != address(wcanto)) {
            revert InvalidPath();
        }
        Route[] memory routes = _pathToRoutes(path);
        amounts = getAmountsOut(amountIn, routes);
        if (amounts[amounts.length - 1] < amountOutMin) {
            revert InsufficientOutputAmount();
        }
        _safeTransferFrom(
            routes[0].from,
            msg.sender,
            pairFor(routes[0].from, routes[0].to),
            amounts[0]
        );
        _swap(amounts, routes, address(this));
        wcanto.withdraw(amounts[amounts.length - 1]);
        _safeTransferETH(to, amounts[amounts.length - 1]);
    }

    // **** SWAP (supporting fee-on-transfer tokens) ****
    // requires the initial amount to have already been sent to the first pair
    function _swapSupportingFeeOnTransferTokens(
        address[] memory path,
        address _to
    ) internal virtual {
        for (uint256 i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0, ) = sortTokens(input, output);
            ILeetSwapV2Pair pair = ILeetSwapV2Pair(pairFor(input, output));
            uint256 amountInput;
            uint256 amountOutput;
            {
                // scope to avoid stack too deep errors
                (uint256 reserve0, uint256 reserve1, ) = pair.getReserves();
                (uint256 reserveInput, ) = input == token0
                    ? (reserve0, reserve1)
                    : (reserve1, reserve0);
                amountInput =
                    IERC20(input).balanceOf(address(pair)) -
                    reserveInput;
                amountOutput = getAmountOut(amountInput, input, output);
            }
            (uint256 amount0Out, uint256 amount1Out) = input == token0
                ? (uint256(0), amountOutput)
                : (amountOutput, uint256(0));
            address to;
            if (i < path.length - 2) {
                to = pairFor(output, path[i + 2]);
            } else {
                to = _to;
            }
            pair.swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual ensure(deadline) {
        _safeTransferFrom(
            path[0],
            msg.sender,
            pairFor(path[0], path[1]),
            amountIn
        );
        uint256 balanceBefore = IERC20(path[path.length - 1]).balanceOf(to);
        _swapSupportingFeeOnTransferTokens(path, to);
        if (
            IERC20(path[path.length - 1]).balanceOf(to) - balanceBefore <
            amountOutMin
        ) {
            revert InsufficientOutputAmount();
        }
    }

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable virtual ensure(deadline) {
        if (path[0] != address(wcanto)) revert InvalidPath();
        uint256 amountIn = msg.value;
        IWCANTO(wcanto).deposit{value: amountIn}();
        assert(IWCANTO(wcanto).transfer(pairFor(path[0], path[1]), amountIn));
        uint256 balanceBefore = IERC20(path[path.length - 1]).balanceOf(to);
        _swapSupportingFeeOnTransferTokens(path, to);
        if (
            IERC20(path[path.length - 1]).balanceOf(to) - balanceBefore <
            amountOutMin
        ) {
            revert InsufficientOutputAmount();
        }
    }

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual ensure(deadline) {
        if (path[path.length - 1] != address(wcanto)) {
            revert InvalidPath();
        }
        _safeTransferFrom(
            path[0],
            msg.sender,
            pairFor(path[0], path[1]),
            amountIn
        );
        _swapSupportingFeeOnTransferTokens(path, address(this));
        uint256 amountOut = IERC20(address(wcanto)).balanceOf(address(this));
        if (amountOut < amountOutMin) {
            revert InsufficientOutputAmount();
        }
        IWCANTO(wcanto).withdraw(amountOut);
        _safeTransferETH(to, amountOut);
    }

    // **** ADD LIQUIDITY ****
    function _addLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) internal returns (uint256 amountA, uint256 amountB) {
        if (amountADesired < amountAMin || amountBDesired < amountBMin)
            revert InvalidAmount();
        // create the pair if it doesn"t exist yet
        address _pair = ILeetSwapV2Factory(factory).getPair(
            tokenA,
            tokenB,
            stable
        );
        if (_pair == address(0)) {
            _pair = ILeetSwapV2Factory(factory).createPair(
                tokenA,
                tokenB,
                stable
            );
        }
        (uint256 reserveA, uint256 reserveB) = getReserves(tokenA, tokenB);
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint256 amountBOptimal = quoteLiquidity(
                amountADesired,
                reserveA,
                reserveB
            );
            if (amountBOptimal <= amountBDesired) {
                if (amountBOptimal < amountBMin) {
                    revert InsufficientBAmount();
                }
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint256 amountAOptimal = quoteLiquidity(
                    amountBDesired,
                    reserveB,
                    reserveA
                );
                assert(amountAOptimal <= amountADesired);
                if (amountAOptimal < amountAMin) {
                    revert InsufficientAAmount();
                }
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
        ensure(deadline)
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        )
    {
        _startLiquidityManagement(tokenA, tokenB);

        address pair = pairFor(tokenA, tokenB);
        bool isStable = stablePairs[pair];
        (amountA, amountB) = _addLiquidity(
            tokenA,
            tokenB,
            isStable,
            amountADesired,
            amountBDesired,
            amountAMin,
            amountBMin
        );
        _safeTransferFrom(tokenA, msg.sender, pair, amountA);
        _safeTransferFrom(tokenB, msg.sender, pair, amountB);
        liquidity = ILeetSwapV2Pair(pair).mint(to);

        _stopLiquidityManagement(tokenA, tokenB);
    }

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountCANTOMin,
        address to,
        uint256 deadline
    )
        external
        payable
        ensure(deadline)
        returns (
            uint256 amountToken,
            uint256 amountCANTO,
            uint256 liquidity
        )
    {
        _startLiquidityManagement(token, address(wcanto));

        address pair = pairFor(token, address(wcanto));
        bool isStable = stablePairs[pair];
        (amountToken, amountCANTO) = _addLiquidity(
            token,
            address(wcanto),
            isStable,
            amountTokenDesired,
            msg.value,
            amountTokenMin,
            amountCANTOMin
        );
        _safeTransferFrom(token, msg.sender, pair, amountToken);
        wcanto.deposit{value: amountCANTO}();
        assert(wcanto.transfer(pair, amountCANTO));
        liquidity = ILeetSwapV2Pair(pair).mint(to);
        // refund dust eth, if any
        if (msg.value > amountCANTO) {
            _safeTransferETH(msg.sender, msg.value - amountCANTO);
        }

        _stopLiquidityManagement(token, address(wcanto));
    }

    function _safeTransferETH(address to, uint256 value) internal {
        (bool success, ) = to.call{value: value}(new bytes(0));
        if (!success) revert CantoTransferFailed();
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
    ) public ensure(deadline) returns (uint256 amountA, uint256 amountB) {
        _startLiquidityManagement(tokenA, tokenB);

        address pair = pairFor(tokenA, tokenB);
        if (!ILeetSwapV2Pair(pair).transferFrom(msg.sender, pair, liquidity))
            revert TransferFailed();
        (uint256 amount0, uint256 amount1) = ILeetSwapV2Pair(pair).burn(to);
        (address token0, ) = sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0
            ? (amount0, amount1)
            : (amount1, amount0);
        if (amountA < amountAMin) {
            revert InsufficientAAmount();
        }
        if (amountB < amountBMin) {
            revert InsufficientBAmount();
        }

        _stopLiquidityManagement(tokenA, tokenB);
    }

    function removeLiquidityETH(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountCANTOMin,
        address to,
        uint256 deadline
    )
        public
        ensure(deadline)
        returns (uint256 amountToken, uint256 amountCANTO)
    {
        _startLiquidityManagement(token, address(wcanto));

        (amountToken, amountCANTO) = removeLiquidity(
            token,
            address(wcanto),
            liquidity,
            amountTokenMin,
            amountCANTOMin,
            address(this),
            deadline
        );
        _safeTransfer(token, to, amountToken);
        wcanto.withdraw(amountCANTO);
        _safeTransferETH(to, amountCANTO);

        _stopLiquidityManagement(token, address(wcanto));
    }

    // **** REMOVE LIQUIDITY (supporting fee-on-transfer tokens) ****
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountCANTOMin,
        address to,
        uint256 deadline
    ) public virtual ensure(deadline) returns (uint256 amountCANTO) {
        _startLiquidityManagement(token, address(wcanto));

        (, amountCANTO) = removeLiquidity(
            token,
            address(wcanto),
            liquidity,
            amountTokenMin,
            amountCANTOMin,
            address(this),
            deadline
        );
        _safeTransfer(token, to, IERC20(token).balanceOf(address(this)));
        wcanto.withdraw(amountCANTO);
        _safeTransferETH(to, amountCANTO);

        _stopLiquidityManagement(token, address(wcanto));
    }

    // **** LIBRARY FUNCTIONS ****
    function _safeTransfer(
        address token,
        address to,
        uint256 value
    ) internal {
        if (token.code.length == 0) revert InvalidToken();
        bool success = IERC20(token).transfer(to, value);
        if (!success) revert TransferFailed();
    }

    function _safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 value
    ) internal {
        if (token.code.length == 0) revert InvalidToken();
        bool success = IERC20(token).transferFrom(from, to, value);
        if (!success) revert TransferFailed();
    }

    function setStablePair(address pair, bool stable) external onlyOwner {
        stablePairs[pair] = stable;
    }

    function setStablePairs(address[] calldata pairs, bool[] calldata stable)
        external
        onlyOwner
    {
        if (pairs.length != stable.length) revert ArrayLengthMismatch();
        for (uint256 i = 0; i < pairs.length; i++) {
            stablePairs[pairs[i]] = stable[i];
        }
    }

    function setDeadlineEnabled(bool _enabled) external onlyOwner {
        deadlineEnabled = _enabled;
    }

    function setLiquidityManageableEnabled(bool _enabled) external onlyOwner {
        liquidityManageableEnabled = _enabled;
    }

    function setLiquidityManageableWhitelistEnabled(bool _enabled)
        external
        onlyOwner
    {
        liquidityManageableWhitelistEnabled = _enabled;
    }

    function addLiquidityManageableWhitelist(address token) external onlyOwner {
        isLiquidityManageableWhitelisted[token] = true;
    }

    function removeLiquidityManageableWhitelist(address token)
        external
        onlyOwner
    {
        isLiquidityManageableWhitelisted[token] = false;
    }
}
