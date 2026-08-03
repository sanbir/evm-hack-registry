// SPDX-License-Identifier: MIT
pragma solidity 0.8.14;

import "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { ERC20Pool }         from "../src/ajna/src/ERC20Pool.sol";
import { ERC20PoolFactory }  from "../src/ajna/src/ERC20PoolFactory.sol";
import { ERC721PoolFactory } from "../src/ajna/src/ERC721PoolFactory.sol";
import { PositionManager }   from "../src/ajna/src/PositionManager.sol";
import { RewardsManager }    from "../src/ajna/src/RewardsManager.sol";
import { PoolInfoUtils }     from "../src/ajna/src/PoolInfoUtils.sol";
import { IPool }             from "../src/ajna/src/interfaces/pool/IPool.sol";
import { IPositionManager }  from "../src/ajna/src/interfaces/position/IPositionManager.sol";
import { IPositionManagerOwnerActions } from "../src/ajna/src/interfaces/position/IPositionManagerOwnerActions.sol";
import { Maths }             from "../src/ajna/src/libraries/internal/Maths.sol";

contract MintableToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 a) external { _mint(to, a); }
}

contract AjnaToken is ERC20 {
    constructor() ERC20("Ajna", "AJNA") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
    function burn(uint256 a) external { _burn(msg.sender, a); }
}

/**
 * @title  H-06: staker loses accrued, still-claimable rewards when their bucket goes bankrupt
 * @notice Real, local (no-fork) reproduction. Deploys the REAL Ajna
 *         ERC20PoolFactory / PositionManager / RewardsManager / ERC20Pool, stakes
 *         a real LP position in the top bucket, drives a REAL reserve-auction burn
 *         so the position accrues REAL, claimable AJNA rewards, then drives a REAL
 *         liquidation+settle that bankrupts that bucket. Because
 *         PositionManager.getPositionIndexesFiltered / getLP treat any bucket with
 *         `depositTime <= bankruptcyTime` as gone (PositionManager.sol:192-199 &
 *         getLP), RewardsManager.calculateRewards for the SAME position collapses
 *         from R>0 to 0 — the lender loses rewards they had already earned while
 *         the bucket was solvent.
 */
contract PoC_20074 is Test {
    AjnaToken        internal ajna;
    ERC20PoolFactory internal factory;
    PositionManager  internal positionManager;
    RewardsManager   internal rewards;
    PoolInfoUtils    internal poolUtils;

    MintableToken internal coll;
    MintableToken internal quote;
    ERC20Pool     internal pool;

    // Ajna price indexes (~9.9 .. 9.5), highest price first (settle consumes top bucket first)
    uint256 constant I_9_91 = 3696;
    uint256 constant I_9_81 = 3698;
    uint256 constant I_9_72 = 3700;
    uint256 constant I_9_62 = 3702;
    uint256 constant I_9_52 = 3704;

    address internal lender      = makeAddr("lender");     // deep book liquidity
    address internal feeBorrower = makeAddr("feeBorrower");// repays -> reserves for the burn epoch
    address internal badBorrower = makeAddr("badBorrower");// liquidated -> bankrupts the bucket

    uint256[] internal stakeIndexes; // [I_9_91]

    function setUp() public {
        // foundry.toml pins the 8 external delegatecall libraries at fixed
        // addresses (so the Playground synthetic compiles with concrete link
        // addresses and injects the same runtime via anvil_state). forge does
        // not auto-deploy pinned libraries, so place their runtime here.
        vm.etch(0x0000000000000000000000000000000000000105, vm.getDeployedCode("SettlerActions.sol:SettlerActions"));
        vm.etch(0x0000000000000000000000000000000000000101, vm.getDeployedCode("BorrowerActions.sol:BorrowerActions"));
        vm.etch(0x0000000000000000000000000000000000000102, vm.getDeployedCode("KickerActions.sol:KickerActions"));
        vm.etch(0x0000000000000000000000000000000000000103, vm.getDeployedCode("LenderActions.sol:LenderActions"));
        vm.etch(0x0000000000000000000000000000000000000104, vm.getDeployedCode("TakerActions.sol:TakerActions"));
        vm.etch(0x0000000000000000000000000000000000000106, vm.getDeployedCode("PoolCommons.sol:PoolCommons"));
        vm.etch(0x0000000000000000000000000000000000000107, vm.getDeployedCode("LPActions.sol:LPActions"));
        vm.etch(0x0000000000000000000000000000000000000108, vm.getDeployedCode("PositionNFTSVG.sol:PositionNFTSVG"));

        vm.warp(block.timestamp + 30 weeks);

        ajna            = new AjnaToken();
        factory         = new ERC20PoolFactory(address(ajna));
        positionManager = new PositionManager(factory, new ERC721PoolFactory(address(ajna)));
        rewards         = new RewardsManager(address(ajna), IPositionManager(address(positionManager)));
        poolUtils       = new PoolInfoUtils();
        ajna.mint(address(rewards), 100_000_000 * 1e18);

        coll  = new MintableToken("Collateral", "C");
        quote = new MintableToken("Quote", "Q");
        pool  = ERC20Pool(factory.deployPool(address(coll), address(quote), 0.05 * 1e18));

        stakeIndexes = new uint256[](1);
        stakeIndexes[0] = I_9_91;
    }

    function test_H06_bankrupt_bucket_wipes_already_earned_rewards() public {
        // 1. deep book liquidity so badBorrower can draw a large loan
        _lenderAdd(I_9_81,  5_000 * 1e18);
        _lenderAdd(I_9_72, 11_000 * 1e18);
        _lenderAdd(I_9_62, 25_000 * 1e18);
        _lenderAdd(I_9_52, 30_000 * 1e18);

        // 2. staker mints an LP NFT in the TOP bucket (I_9_91) and stakes it
        uint256 tokenId = _mintMemorialize(2_000 * 1e18);
        positionManager.approve(address(rewards), tokenId);
        rewards.stake(tokenId);
        assertGt(positionManager.getLP(tokenId, I_9_91), 0, "position has LP");

        // 3. two borrowers: one small (for reserves), one large (to be liquidated)
        _drawDebt(feeBorrower, 300 * 1e18, I_9_72, 100 * 1e18);
        _drawDebt(badBorrower, 9_710 * 1e18, I_9_72, 1_000 * 1e18);

        // 4. interest accrues; badBorrower drifts underwater
        vm.warp(block.timestamp + 400 days);
        pool.updateInterest();
        ( , uint256 claimablePre, , , ) = poolUtils.poolReservesInfo(address(pool));
        emit log_named_uint("claimable reserves before kick", claimablePre);

        // 5. real reserve-auction burn -> burn epoch 1, so the staked position
        //    accrues real, claimable rewards for the solvent bucket
        _repayKickTake(feeBorrower);
        assertEq(IPool(address(pool)).currentBurnEpoch(), 1, "epoch != 1");
        rewards.updateBucketExchangeRatesAndClaim(address(pool), stakeIndexes);

        uint256 rewardBefore = rewards.calculateRewards(tokenId, 1);
        assertGt(rewardBefore, 0, "position should have accrued claimable rewards");

        // 6. real liquidation + settle bankrupts the TOP bucket (I_9_91)
        _bankruptTopBucket();
        ( , , uint256 bankruptcyTime, , ) = pool.bucketInfo(I_9_91);
        assertGt(bankruptcyTime, 0, "bucket did not go bankrupt");

        // 7. HARM: the SAME already-earned rewards are now wiped to 0, and the
        //    tracked LP is treated as 0 — the lender loses rewards they had earned
        //    while the bucket was solvent.
        uint256 rewardAfter = rewards.calculateRewards(tokenId, 1);
        assertEq(rewardAfter, 0, "rewards should be wiped after bankruptcy (the bug)");
        assertEq(positionManager.getLP(tokenId, I_9_91), 0, "tracked LP zeroed for bankrupt bucket");

        // 8. unstaking now pays the staker nothing, even though rewardBefore was claimable
        uint256 balBefore = ajna.balanceOf(address(this));
        rewards.unstake(tokenId);
        uint256 gained = ajna.balanceOf(address(this)) - balBefore;
        assertEq(gained, 0, "staker receives 0 rewards");

        emit log_named_uint("rewards claimable BEFORE bankruptcy (AJNA) ", rewardBefore);
        emit log_named_uint("rewards claimable AFTER  bankruptcy (AJNA) ", rewardAfter);
        emit log_named_uint("AJNA rewards actually received on unstake   ", gained);
        emit log_named_uint("AJNA rewards LOST                           ", rewardBefore - gained);
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _lenderAdd(uint256 index, uint256 amount) internal {
        quote.mint(lender, amount);
        vm.startPrank(lender);
        quote.approve(address(pool), type(uint256).max);
        pool.addQuoteToken(amount, index, type(uint256).max);
        vm.stopPrank();
    }

    function _mintMemorialize(uint256 amount) internal returns (uint256 tokenId) {
        quote.mint(address(this), amount);
        quote.approve(address(pool), type(uint256).max);

        IPositionManagerOwnerActions.MintParams memory mintParams =
            IPositionManagerOwnerActions.MintParams(address(this), address(pool), keccak256("ERC20_NON_SUBSET_HASH"));
        tokenId = positionManager.mint(mintParams);

        pool.addQuoteToken(amount, I_9_91, type(uint256).max);
        (uint256 lp, ) = pool.lenderInfo(I_9_91, address(this));
        uint256[] memory lps = new uint256[](1);
        lps[0] = lp;
        pool.increaseLPAllowance(address(positionManager), stakeIndexes, lps);

        IPositionManagerOwnerActions.MemorializePositionsParams memory mp =
            IPositionManagerOwnerActions.MemorializePositionsParams(tokenId, stakeIndexes);
        positionManager.memorializePositions(mp);
    }

    function _drawDebt(address who, uint256 borrowAmount, uint256 limitIndex, uint256 collateralPledge) internal {
        coll.mint(who, collateralPledge);
        vm.startPrank(who);
        coll.approve(address(pool), type(uint256).max);
        pool.drawDebt(who, borrowAmount, limitIndex, collateralPledge);
        vm.stopPrank();
    }

    function _repayKickTake(address who) internal {
        quote.mint(who, 1_000_000 * 1e18);
        vm.startPrank(who);
        quote.approve(address(pool), type(uint256).max);
        pool.repayDebt(who, type(uint256).max, 0, who, 7388);
        vm.stopPrank();

        pool.kickReserveAuction();
        vm.warp(block.timestamp + 24 hours);
        ( , , uint256 claimable, , ) = poolUtils.poolReservesInfo(address(pool));
        ajna.mint(address(this), 900_000_000 * 1e18);
        ajna.approve(address(pool), type(uint256).max);
        pool.takeReserves(claimable);
    }

    // kick + take + settle badBorrower -> the top bucket absorbs the bad debt and goes bankrupt
    function _bankruptTopBucket() internal {
        quote.mint(address(this), 2_000_000 * 1e18);
        quote.approve(address(pool), type(uint256).max);

        pool.kick(badBorrower, 7388);
        vm.warp(block.timestamp + 10 hours);
        pool.take(badBorrower, 1_000 * 1e18, address(this), "");
        pool.settle(badBorrower, 10);
    }
}
