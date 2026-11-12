// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Beraji KO — fullyClaimReward nests updateReward (Shieldify H-02, finding 49514).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Four locks and four rewards make 16 cells of 100, so the fair claim is
    1600. _claimReward carries updateReward, and that modifier walks all 16
    cells again, so the full claim cannot finish inside the gas stipend and
    the user is paid 0. The control claims the same 16 cells without the
    modifier and pays 1600. The blamed modifier is preserved (@> VULN).
    run() does not warp. */

contract RewardToken {
    string public symbol = "RWD";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract StakingKo {
    uint256 public constant COUNT = 4;
    RewardToken public reward;
    uint256[4][4] public owed;
    uint256 public scratch;
    uint256 public paid;

    constructor(address reward_) {
        reward = RewardToken(reward_);
        for (uint256 i; i < COUNT; i++) {
            for (uint256 j; j < COUNT; j++) {
                owed[i][j] = 100 ether;
            }
        }
    }

    modifier updateReward() {
        uint256 n = COUNT;
        for (uint256 i; i < n; i++) {
            for (uint256 j; j < n; j++) {
                // @> VULN: updateReward walks every lock and reward again inside each _claimReward
                scratch = uint256(keccak256(abi.encode(scratch, i, j)));
            }
        }
        _;
    }

    function _claimReward(uint256 lockId, uint256 rewardId) internal updateReward {
        uint256 rwAmount = owed[lockId][rewardId];
        if (rwAmount != 0) {
            owed[lockId][rewardId] = 0;
            paid += rwAmount;
            require(reward.transfer(msg.sender, rwAmount), "pay");
        }
    }

    function fullyClaimReward() external {
        uint256 n = COUNT;
        for (uint256 i; i < n; i++) {
            for (uint256 j; j < n; j++) {
                _claimReward(i, j);
            }
        }
    }
}

contract StakingKoFixed {
    uint256 public constant COUNT = 4;
    RewardToken public reward;
    uint256[4][4] public owed;
    uint256 public paid;

    constructor(address reward_) {
        reward = RewardToken(reward_);
        for (uint256 i; i < COUNT; i++) {
            for (uint256 j; j < COUNT; j++) {
                owed[i][j] = 100 ether;
            }
        }
    }

    function _claimReward(uint256 lockId, uint256 rewardId) internal {
        uint256 rwAmount = owed[lockId][rewardId];
        if (rwAmount != 0) {
            owed[lockId][rewardId] = 0;
            paid += rwAmount;
            require(reward.transfer(msg.sender, rwAmount), "pay");
        }
    }

    function fullyClaimReward() external {
        uint256 n = COUNT;
        for (uint256 i; i < n; i++) {
            for (uint256 j; j < n; j++) {
                _claimReward(i, j);
            }
        }
    }
}

contract Exploit {
    uint256 public constant FAIR = 1600 ether;
    uint256 public constant GAS_BUDGET = 250_000;

    RewardToken public reward; // CREATE nonce 1
    StakingKo public staking; // CREATE nonce 2
    StakingKoFixed public control; // CREATE nonce 3

    uint256 public paidBuggy;
    uint256 public stuck;
    uint256 public paidControl;

    constructor() {
        reward = new RewardToken();
        staking = new StakingKo(address(reward));
        control = new StakingKoFixed(address(reward));
    }

    function run() external {
        reward.mint(address(staking), FAIR);
        reward.mint(address(control), FAIR);
        try staking.fullyClaimReward{gas: GAS_BUDGET}() {} catch {}
        paidBuggy = staking.paid();
        stuck = reward.balanceOf(address(staking));
        require(paidBuggy < FAIR, "nested claim paid the fair amount");
        require(stuck == FAIR - paidBuggy, "unpaid rewards left the contract");

        control.fullyClaimReward{gas: GAS_BUDGET}();
        paidControl = control.paid();
        require(paidControl == FAIR, "control did not pay 1600");
        require(reward.balanceOf(address(this)) == FAIR, "user did not receive the fair claim");
    }
}
