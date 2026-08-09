// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of HYBUX finding 63683:
// "[C-01] Incorrect reward calculation".
//
// NFTStaking._unstakeNFTs() pays out accrued rewards by calling claimRewards(),
// which internally uses _claimRewards(msg.sender). This is correct for a direct
// unstake (msg.sender == the staker), but WRONG when unstaking is delegated
// through the staking router: unstakeNFTsRouter(_sender, ids) passes the real
// user as `_sender`, yet _unstakeNFTs then claims for msg.sender == the router.
// The router holds no position, so _claimRewards(router) pays ~0, and the user's
// accrued rewards are then WIPED when their position/checkpoint is cleared. The
// user permanently forfeits their rewards.
//
// Verbatim vulnerable functions inlined from the finding (NFTStaking.sol L82-90,
// L182-183). The single defective line is `claimRewards();` inside _unstakeNFTs,
// marked `// @>` — it consults msg.sender instead of the delegated `_sender`.
// ─────────────────────────────────────────────────────────────────────────────

interface IRewardToken {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

interface INFT {
    function transferFrom(address from, address to, uint256 tokenId) external;
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @dev Minimal ERC20 double for the HYBUX reward token (opaque external asset).
///      Also reused as the harm MARKER token.
contract MockRewardToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Minimal ERC721 double for the staked collection (opaque external asset).
contract MockERC721 {
    mapping(uint256 => address) public ownerOf;

    function mint(address to, uint256 tokenId) external {
        ownerOf[tokenId] = to;
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == from, "not owner");
        ownerOf[tokenId] = to;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — verbatim buggy router/claim/unstake triple inlined.
// ─────────────────────────────────────────────────────────────────────────────
contract NFTStaking {
    IRewardToken public rewardToken;
    INFT public nft;
    address public stakingRouterAddress;

    mapping(address => uint256[]) internal stakedTokens; // per-user staked NFT ids
    mapping(address => uint256) public rewards;          // accrued, unclaimed rewards

    constructor(address _rewardToken, address _nft) {
        rewardToken = IRewardToken(_rewardToken);
        nft = INFT(_nft);
    }

    function setStakingRouter(address _router) external {
        stakingRouterAddress = _router;
    }

    /// @notice Test setter to pre-populate a staked position + its accrued
    ///         rewards (represents days of accrual — accrual curve is out of scope).
    function seedPosition(address _sender, uint256[] calldata _tokenIds, uint256 _pending) external {
        delete stakedTokens[_sender];
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            stakedTokens[_sender].push(_tokenIds[i]);
        }
        rewards[_sender] = _pending;
    }

    function stakedCount(address _sender) external view returns (uint256) {
        return stakedTokens[_sender].length;
    }

    // ── verbatim vulnerable source (NFTStaking.sol) ──────────────────────────
    function unstakeNFTsRouter(address _sender, uint256[] calldata _tokenIds) external {
        require(msg.sender == stakingRouterAddress, "Only router");

        _unstakeNFTs(_sender, _tokenIds);
    }

    function claimRewards() public {
        _claimRewards(msg.sender);
    }

    function _unstakeNFTs(address _sender, uint256[] calldata _tokenIds) internal {
        claimRewards(); // @> pays _claimRewards(msg.sender)=router, not the delegated _sender; user's accrued reward is then wiped below
        // clear the user's position and reward checkpoint, and return the NFTs
        rewards[_sender] = 0;
        delete stakedTokens[_sender];
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            nft.transferFrom(address(this), _sender, _tokenIds[i]);
        }
    }
    // ─────────────────────────────────────────────────────────────────────────

    function _claimRewards(address _sender) internal {
        uint256 amount = rewards[_sender];
        rewards[_sender] = 0;
        if (amount > 0) {
            rewardToken.transfer(_sender, amount);
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract — _unstakeNFTs claims for the delegated `_sender`.
// ─────────────────────────────────────────────────────────────────────────────
contract NFTStakingFixed {
    IRewardToken public rewardToken;
    INFT public nft;
    address public stakingRouterAddress;

    mapping(address => uint256[]) internal stakedTokens;
    mapping(address => uint256) public rewards;

    constructor(address _rewardToken, address _nft) {
        rewardToken = IRewardToken(_rewardToken);
        nft = INFT(_nft);
    }

    function setStakingRouter(address _router) external {
        stakingRouterAddress = _router;
    }

    function seedPosition(address _sender, uint256[] calldata _tokenIds, uint256 _pending) external {
        delete stakedTokens[_sender];
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            stakedTokens[_sender].push(_tokenIds[i]);
        }
        rewards[_sender] = _pending;
    }

    function stakedCount(address _sender) external view returns (uint256) {
        return stakedTokens[_sender].length;
    }

    function unstakeNFTsRouter(address _sender, uint256[] calldata _tokenIds) external {
        require(msg.sender == stakingRouterAddress, "Only router");

        _unstakeNFTs(_sender, _tokenIds);
    }

    function claimRewards() public {
        _claimRewards(msg.sender);
    }

    function _unstakeNFTs(address _sender, uint256[] calldata _tokenIds) internal {
        _claimRewards(_sender); // FIX: claim for the delegated user, not msg.sender
        rewards[_sender] = 0;
        delete stakedTokens[_sender];
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            nft.transferFrom(address(this), _sender, _tokenIds[i]);
        }
    }

    function _claimRewards(address _sender) internal {
        uint256 amount = rewards[_sender];
        rewards[_sender] = 0;
        if (amount > 0) {
            rewardToken.transfer(_sender, amount);
        }
    }
}

/// @dev Minimal faithful double for the staking router: forwards the real user
///      as `_sender` while itself being msg.sender to the staking contract.
contract StakingRouter {
    address public staking;

    constructor(address _staking) {
        staking = _staking;
    }

    function unstakeNFTs(address _sender, uint256[] calldata _tokenIds) external {
        NFTStaking(staking).unstakeNFTsRouter(_sender, _tokenIds);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: Alice stakes and accrues 1000 rewards, then unstakes via the
// router. The router (msg.sender) holds no position, so her reward is paid to no
// one and wiped. Harm (her forfeited reward) is recorded on a MARKER to the SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ALICE = 0x000000000000000000000000000000000000a11c;

    uint256 internal constant TOKEN_ID = 42;
    uint256 internal constant ACCRUED = 1000 ether; // 1000 HYBUX accrued by Alice

    MockRewardToken internal reward;
    MockERC721 internal nft;
    NFTStaking internal staking;
    StakingRouter internal router;
    MockRewardToken internal marker;

    // Exposed results.
    uint256 public aliceRewardBalance;
    uint256 public routerRewardBalance;
    uint256 public alicePendingAfter;
    uint256 public aliceStakedAfter;
    uint256 public lostAmount;
    uint256 public sinkMarkerBalance;
    address public rewardAddr;
    address public stakingAddr;
    address public routerAddr;
    address public markerAddr;
    address public aliceAddr;

    constructor() {
        // Fixed deploy order; marker LAST.
        reward = new MockRewardToken("HYBUX Reward", "HYBUX");    // nonce 1
        nft = new MockERC721();                                   // nonce 2
        staking = new NFTStaking(address(reward), address(nft));  // nonce 3
        router = new StakingRouter(address(staking));             // nonce 4
        marker = new MockRewardToken("Lost HYBUX", "LOST-HYBUX"); // nonce 5 (LAST)

        staking.setStakingRouter(address(router));

        rewardAddr = address(reward);
        stakingAddr = address(staking);
        routerAddr = address(router);
        markerAddr = address(marker);
        aliceAddr = ALICE;
    }

    function run() external payable {
        // --- setup: Alice's NFT is staked; the reward pool is funded ---
        nft.mint(address(staking), TOKEN_ID);          // NFT held by staking (staked)
        uint256[] memory ids = new uint256[](1);
        ids[0] = TOKEN_ID;
        staking.seedPosition(ALICE, ids, ACCRUED);     // Alice: 1 NFT + 1000 accrued
        reward.mint(address(staking), ACCRUED);        // reward pool held by staking

        // --- Alice unstakes THROUGH the router (the real buggy path) ---
        router.unstakeNFTs(ALICE, ids);

        // --- measure the harm ---
        aliceRewardBalance = reward.balanceOf(ALICE);       // never paid  -> 0
        routerRewardBalance = reward.balanceOf(address(router)); // router had no position -> 0
        alicePendingAfter = staking.rewards(ALICE);         // wiped       -> 0
        aliceStakedAfter = staking.stakedCount(ALICE);      // cleared     -> 0

        // Alice was owed ACCRUED, received 0, and her accrual is now unrecoverable.
        require(aliceRewardBalance == 0, "alice unexpectedly paid");
        require(alicePendingAfter == 0, "alice pending not wiped");
        require(nft.ownerOf(TOKEN_ID) == ALICE, "nft not returned");
        lostAmount = ACCRUED - aliceRewardBalance;
        require(lostAmount == ACCRUED, "no forfeiture");

        // record the forfeited magnitude on the MARKER token at the SINK
        marker.mint(SINK, lostAmount);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
