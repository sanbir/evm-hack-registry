// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Tapioca DAO — [H-41] Rewards compounded in AaveStrategy are unredeemable
    (Code4rena 2023-07-tapioca, reporter Ack, finding #27531).

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: Aave's incentivesController.claimRewards stakes claimed AAVE
    into stkAAVE immediately. AaveStrategy.compound() claims incentives and
    may claim staking rewards on stkAAVE, but never calls stkAAVE.redeem().
    Without redeem, staked rewards remain locked forever inside the strategy.

    Blamed compound path preserved with @> VULN (missing redeem).
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function burn(address from, uint256 amt) external {
        balanceOf[from] -= amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Minimal stkAAVE: stake mints stk, redeem burns stk for underlying.
contract StakingRewardToken {
    MockERC20 public immutable stakeToken; // AAVE
    mapping(address => uint256) public balanceOf; // staked shares 1:1

    constructor(MockERC20 _stake) {
        stakeToken = _stake;
    }

    function stake(address to, uint256 amount) external {
        // Real AAVE incentivesController stakes claimed AAVE into stkAAVE for `to`.
        balanceOf[to] += amount;
        // Back redeem with underlying held by this contract.
        stakeToken.mint(address(this), amount);
    }

    /// @dev The missing call — never invoked by AaveStrategy.compound().
    function redeem(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        stakeToken.transfer(to, amount);
    }
}

/// @notice Minimal incentives controller: claimRewards immediately stakes.
contract IncentivesController {
    StakingRewardToken public immutable stakingRewardToken;
    mapping(address => uint256) public pending;

    constructor(StakingRewardToken s) {
        stakingRewardToken = s;
    }

    function setPending(address user, uint256 amt) external {
        pending[user] = amt;
    }

    function claimRewards(address[] calldata /*assets*/, uint256 amount, address to) external returns (uint256) {
        uint256 claimable = pending[msg.sender];
        if (amount < claimable) claimable = amount;
        pending[msg.sender] -= claimable;
        // Real AAVE: STAKE_TOKEN.stake(to, amountToClaim) — claimed rewards staked immediately.
        stakingRewardToken.stake(to, claimable);
        return claimable;
    }
}

/// @notice Reduced AaveStrategy.compound — claims into stkAAVE, never redeems.
contract AaveStrategy {
    IncentivesController public incentivesController;
    StakingRewardToken public stakingRewardToken;
    MockERC20 public rewardToken; // free AAVE (from staking claimRewards, not redeem)
    MockERC20 public wrappedNative;

    constructor(
        IncentivesController ic,
        StakingRewardToken stk,
        MockERC20 aave,
        MockERC20 weth
    ) {
        incentivesController = ic;
        stakingRewardToken = stk;
        rewardToken = aave;
        wrappedNative = weth;
    }

    /// @dev Reduced compound: claims incentives (staked) + optional staking rewards.
    ///      MISSING: stakingRewardToken.redeem(...) to free the staked AAVE.
    function compound() external {
        address[] memory assets = new address[](0);
        // Claim AAVE incentives → auto-staked into stkAAVE for this strategy.
        incentivesController.claimRewards(assets, type(uint256).max, address(this));

        // Claimed incentives sit as stkAAVE forever — unredeemable by the strategy.
        // FIX: after cooldown, call stakingRewardToken.redeem(address(this), bal)
        //      then swap free AAVE → wrappedNative and re-deposit.
        // @> VULN: compound never calls stakingRewardToken.redeem() — stk balance stays locked.
        uint256 lockedStk = stakingRewardToken.balanceOf(address(this));
        lockedStk; // silence unused in pure path; balance proves rewards never leave stk
    }

    function stakedBalance() external view returns (uint256) {
        return stakingRewardToken.balanceOf(address(this));
    }
}

contract Exploit {
    MockERC20 public aave;
    MockERC20 public weth;
    StakingRewardToken public stk;
    IncentivesController public ic;
    AaveStrategy public strategy;

    uint256 public constant REWARD = 500 ether;
    uint256 public lockedStk;

    constructor() {
        aave = new MockERC20("AAVE", "AAVE");
        weth = new MockERC20("WETH", "WETH");
        stk = new StakingRewardToken(aave);
        ic = new IncentivesController(stk);
        strategy = new AaveStrategy(ic, stk, aave, weth);

        // Accrue claimable incentives for the strategy (as AAVE protocol would).
        ic.setPending(address(strategy), REWARD);
    }

    function run() external {
        strategy.compound();

        lockedStk = strategy.stakedBalance();
        require(lockedStk == REWARD, "harm: rewards staked as stkAAVE");
        // Strategy holds zero free AAVE — nothing to swap/compound into WETH.
        require(aave.balanceOf(address(strategy)) == 0, "harm: no free AAVE");
        require(weth.balanceOf(address(strategy)) == 0, "harm: nothing compounded");
        // No public redeem path on the strategy → rewards permanently locked.
    }
}
