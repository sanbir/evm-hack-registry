pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import {ReentrancyGuard} from "openzeppelin-0.7/utils/ReentrancyGuard.sol";

import {IERC20} from "openzeppelin-0.7/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-0.7/token/ERC20/SafeERC20.sol";

import {SafeMath} from "openzeppelin-0.7/math/SafeMath.sol";

import {IWETH9 as IWETH} from "../interfaces/IWETH9.sol";

import {IBazaarLBP} from "../interfaces/IBazaarLBP.sol";
import {IBazaarVault} from "../interfaces/IBazaarVault.sol";

import {WeightedMath} from "balancer-lbp-patch/v2-pool-weighted/contracts/WeightedMath.sol";

// @notice A sub-implementation of the Balancer `IVault` interface backing the
//         the Balancer Pools created from the BazaarLBPFactory. This solely enables
//         Join/Exit/Swap functionality.
contract BazaarVault is ReentrancyGuard, IBazaarVault {
    using SafeMath for uint256;

    uint256 private constant TOKENS_LENGTH = 2;

    // The swap/join/exit requests support native ETH over WETH
    // if the caller uses the zero address as the sentinel value
    // over WETH.
    IWETH public immutable WETH;
    address private immutable eth = address(0);

    uint256 internal poolNonce;
    mapping(bytes32 => bool) public pools;
    mapping(bytes32 => address[]) public poolTokens;
    mapping(bytes32 => mapping(address => uint256)) public poolBalances;

    constructor(address _weth) {
        WETH = IWETH(_weth);
    }

    modifier registeredPool(bytes32 poolId) {
        require(pools[poolId], "pool unregistered");
        _;
    }

    // @notice UNSUPPORTED
    function getProtocolFeesCollector() external pure override returns (address) {
        return address(0);
    }

    function registerPool(PoolSpecialization specialization) external override nonReentrant returns (bytes32 poolId) {
        require(specialization == PoolSpecialization.TWO_TOKEN, "only two token specialization support");

        uint256 nonce = poolNonce;
        poolNonce++;

        // Use the same serialization pattern
        poolId |= bytes32(uint256(nonce));
        poolId |= bytes32(uint256(specialization)) << (10 * 8);
        poolId |= bytes32(uint256(msg.sender)) << (12 * 8);

        pools[poolId] = true;
    }

    function registerTokens(bytes32 poolId, address[] memory tokens, address[] memory)
        external
        override
        registeredPool(poolId)
    {
        require(poolTokens[poolId].length == 0, "pool tokens already registered");
        require(tokens.length == TOKENS_LENGTH, "only two token pools supported");

        // All addresses must be specified -- address(0) sentinel is translated
        tokens = _translateToErc20s(tokens);
        require(tokens[0] < tokens[1], "tokens must be ordered and specified");

        poolTokens[poolId] = tokens;
    }

    function getPoolTokens(bytes32 poolId)
        public
        view
        override
        returns (address[] memory tokens, uint256[] memory balances, uint256)
    {
        tokens = poolTokens[poolId];
        balances = new uint256[](tokens.length);
        for (uint256 i = 0; i < balances.length; i++) {
            balances[i] = poolBalances[poolId][tokens[i]];
        }
    }

    function swap(SingleSwap memory singleSwap, FundManagement memory funds, uint256 limit, uint256 deadline)
        external
        payable
        override
        nonReentrant
        registeredPool(singleSwap.poolId)
        returns (uint256 amountCalculated)
    {
        require(!funds.fromInternalBalance && !funds.toInternalBalance, "internal balance unsupported");
        require(singleSwap.amount > 0, "zero swap amount");
        require(block.timestamp <= deadline, "deadline exceeded");

        IBazaarLBP.SwapRequest memory request;
        request.poolId = singleSwap.poolId;
        request.kind = singleSwap.kind;
        request.amount = singleSwap.amount;
        request.userData = singleSwap.userData;
        request.from = funds.sender;
        request.to = funds.recipient;

        // Pools only holds an ERC20 balances. This ensures a ETH <> WETH conversion
        request.tokenIn = _translateToErc20(singleSwap.tokenIn);
        request.tokenOut = _translateToErc20(singleSwap.tokenOut);
        require(request.tokenIn != request.tokenOut, "same swap tokens");

        uint256 balanceIn = poolBalances[request.poolId][request.tokenIn];
        uint256 balanceOut = poolBalances[request.poolId][request.tokenOut];
        require(balanceIn > 0 && balanceOut > 0, "invalid tokens specified. zero balance");

        // Compute swap amounts
        IBazaarLBP lbp = IBazaarLBP(_getPoolAddress(request.poolId));
        amountCalculated = lbp.onSwap(request, balanceIn, balanceOut);
        (uint256 amountIn, uint256 amountOut) = _getAmounts(request.kind, request.amount, amountCalculated);
        require(request.kind == SwapKind.GIVEN_IN ? amountOut >= limit : amountIn <= limit, "limit exceeded");

        poolBalances[request.poolId][request.tokenIn] = poolBalances[request.poolId][request.tokenIn].add(amountIn);
        poolBalances[request.poolId][request.tokenOut] = poolBalances[request.poolId][request.tokenOut].sub(amountOut);

        // Transfer funds (use original `singleSwap.token(In|Out) address)` so we know
        // if caller desires `eth` or `WETH` when transferring funds if applicable
        _receiveFunds(singleSwap.tokenIn, request.from, amountIn);
        _sendFunds(singleSwap.tokenOut, request.to, amountOut);

        emit Swap(request.poolId, request.tokenIn, request.tokenOut, amountIn, amountOut);
    }

    function querySwap(SingleSwap memory singleSwap)
        public
        view
        override
        registeredPool(singleSwap.poolId)
        returns (uint256 amountCalculated)
    {
        IBazaarLBP.SwapRequest memory request;
        request.poolId = singleSwap.poolId;
        request.kind = singleSwap.kind;
        request.amount = singleSwap.amount;
        request.tokenIn = _translateToErc20(singleSwap.tokenIn);
        request.tokenOut = _translateToErc20(singleSwap.tokenOut);

        uint256 balanceIn = poolBalances[request.poolId][request.tokenIn];
        uint256 balanceOut = poolBalances[request.poolId][request.tokenOut];
        require(balanceIn > 0 && balanceOut > 0, "invalid tokens specified. zero balance");

        IBazaarLBP lbp = IBazaarLBP(_getPoolAddress(request.poolId));
        amountCalculated = lbp.querySwap(request, balanceIn, balanceOut);
    }

    function joinPool(bytes32 poolId, address sender, address recipient, JoinPoolRequest memory request)
        external
        payable
        override
        nonReentrant
        registeredPool(poolId)
    {
        (address[] memory tokens, uint256[] memory balances,) = getPoolTokens(poolId);
        require(tokens.length == TOKENS_LENGTH && tokens.length == request.tokens.length, "mismatch token length");

        IBazaarLBP lbp = IBazaarLBP(_getPoolAddress(poolId));
        (uint256[] memory amountsIn,) = lbp.onJoinPool(poolId, sender, recipient, balances, 0, 0, request.userData);
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 amountIn = amountsIn[i];
            require(amountIn <= request.maxAmountsIn[i], "limit exceeded");
            require(tokens[i] == _translateToErc20(request.tokens[i]), "token mismatch");

            address token = tokens[i];
            poolBalances[poolId][token] = poolBalances[poolId][token].add(amountIn);

            // use original address such that ETH is supported
            _receiveFunds(request.tokens[i], sender, amountIn);
        }
    }

    function exitPool(bytes32 poolId, address sender, address payable recipient, ExitPoolRequest memory request)
        external
        override
        nonReentrant
        registeredPool(poolId)
    {
        (address[] memory tokens, uint256[] memory balances,) = getPoolTokens(poolId);
        require(tokens.length == TOKENS_LENGTH && tokens.length == request.tokens.length, "mismatch tokens length");

        IBazaarLBP lbp = IBazaarLBP(_getPoolAddress(poolId));
        (uint256[] memory amountsOut,) = lbp.onExitPool(poolId, sender, recipient, balances, 0, 0, request.userData);

        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 amountOut = amountsOut[i];
            require(amountOut >= request.minAmountsOut[i], "limit not reached");
            require(tokens[i] == _translateToErc20(request.tokens[i]), "token mismatch");

            address token = tokens[i];
            poolBalances[poolId][token] = poolBalances[poolId][token].sub(amountOut);

            // use original address such that ETH is supported
            _sendFunds(request.tokens[i], recipient, amountOut);
        }
    }

    // Helpers

    function _getAmounts(SwapKind kind, uint256 amountGiven, uint256 amountCalculated)
        internal
        pure
        returns (uint256 amountIn, uint256 amountOut)
    {
        if (kind == SwapKind.GIVEN_IN) {
            (amountIn, amountOut) = (amountGiven, amountCalculated);
        } else {
            // SwapKind.GIVEN_OUT
            (amountIn, amountOut) = (amountCalculated, amountGiven);
        }
    }

    function _getPoolAddress(bytes32 poolId) internal pure returns (address) {
        return address(uint256(poolId) >> (12 * 8));
    }

    function _translateToErc20(address token) internal view returns (address) {
        if (token == eth) {
            return address(WETH);
        } else {
            return token;
        }
    }

    function _translateToErc20s(address[] memory tokens) internal view returns (address[] memory) {
        address[] memory translated = new address[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            translated[i] = _translateToErc20(tokens[i]);
        }

        return translated;
    }

    function _receiveFunds(address token, address sender, uint256 amount) internal {
        if (amount == 0) {
            return;
        }

        if (token == eth) {
            require(msg.value >= amount, "insufficient eth/WETH");

            // Consume needed ETH as WETH. Adjust the amount of WETH to
            // be transferred from the sender at the end of this call
            WETH.deposit{value: amount}();

            // Refund excess ETH to the sender
            // NOTICE: We don't have to worry about recieving ETH multiple times
            //         in a single call (also nonReentrant) since we're only supporting
            //         two token pools.  Even > 2 token pools, WETH can only be specified
            //         as one of the tokens. Hence we can refund excess ETH immediately
            uint256 excess = msg.value - amount;
            if (excess > 0) {
                (bool success,) = sender.call{value: excess}("");
                require(success, "failed refund");
            }
        } else {
            // Transfer ERC20 as normal (includes WETH)
            SafeERC20.safeTransferFrom(IERC20(token), sender, address(this), amount);
        }
    }

    function _sendFunds(address token, address recipient, uint256 amount) internal {
        if (amount == 0) {
            return;
        }

        if (token == eth) {
            // If specified ETH, withdraw and disperse ETH
            WETH.withdraw(amount);
            (bool success,) = recipient.call{value: amount}("");
            require(success, "failed eth dispersement");
        } else {
            // Transfer ERC20 as normal (includes WETH)
            SafeERC20.safeTransfer(IERC20(token), recipient, amount);
        }
    }

    // @notice required to enable ETH dispersements from the internal WETH balance that is held
    receive() external payable {
        require(msg.sender == address(WETH), "only WETH withdrawals");
    }
}
