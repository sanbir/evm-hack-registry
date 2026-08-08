// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Ajna Grants (StandardFunding) — Delegation rewards are not counted toward
    granting fund (Code4rena 2023-05, [H-04], finding #20072)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground. The vulnerable
    StandardFunding._updateTreasury line is inlined VERBATIM:

        treasury += (fundsAvailable - totalTokensRequested);

    `fundsAvailable` is 100% of a period's Global Budget Constraint (GBC); winning
    proposals may request at most 90% of it, and the other 10% is paid out to voters
    via claimDelegateReward(). But _updateTreasury re-adds `fundsAvailable -
    totalTokensRequested` (≈ 10%) to the treasury WITHOUT subtracting the delegate
    rewards that were actually paid — so the treasury's booked balance drifts above
    the AJNA it actually holds by exactly the delegate rewards, every period. Left
    unchecked the treasury becomes insolvent (it books grants it cannot honor).

    _getDelegateReward (the 10%-of-GBC formula) and the startNewDistributionPeriod
    GBC/treasury math are inlined verbatim too. The screening/funding/slate voting
    machinery is reduced to a direct setup of its RESULT (a funded slate + voter
    power), and block-number challenge-period gating is stripped (needs no cheats).
//////////////////////////////////////////////////////////////////////////*/

/// @dev Ajna WAD math (half-up rounding), matching ajna-grants Maths.
library Maths {
    uint256 internal constant WAD = 1e18;

    function wmul(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x * y + WAD / 2) / WAD;
    }

    function wdiv(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x * WAD + y / 2) / y;
    }
}

library SafeCast {
    function toUint128(uint256 x) internal pure returns (uint128) {
        require(x <= type(uint128).max, "overflow");
        return uint128(x);
    }
}

/// @dev Minimal AJNA ERC20.
contract MockAjna {
    string public constant name = "Ajna";
    string public constant symbol = "AJNA";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (msg.sender != from) allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Reduced Ajna GrantFund (StandardFunding). Treasury accounting, the
///         verbatim _updateTreasury bug, the verbatim _getDelegateReward formula,
///         and the verbatim startNewDistributionPeriod GBC math.
contract GrantFund {
    using Maths for uint256;

    error DelegateRewardInvalid();
    error RewardAlreadyClaimed();

    event DelegateRewardClaimed(address indexed delegateeAddress, uint24 indexed distributionId, uint256 rewardClaimed);

    /// @notice Maximum percentage of the treasury distributable in a quarter (3%).
    uint256 internal constant GLOBAL_BUDGET_CONSTRAINT = 0.03 * 1e18;

    struct QuarterlyDistribution {
        uint24 id;
        uint128 fundsAvailable; // 100% of the period GBC
        bytes32 fundedSlateHash;
        uint256 fundingVotePowerCast; // total voting power allocated in the funding stage
    }

    struct Proposal {
        uint256 tokensRequested;
        address recipient;
        bool executed;
    }

    struct QuadraticVoter {
        uint128 votingPower;
        uint128 remainingVotingPower;
    }

    address public immutable ajnaTokenAddress;

    /// @notice The treasury's BOOKED balance (should track the AJNA actually held).
    uint256 public treasury;

    uint24 internal _currentDistributionId;
    mapping(uint24 => QuarterlyDistribution) internal _distributions;
    mapping(bytes32 => uint256[]) internal _fundedProposalSlates;
    mapping(uint256 => Proposal) internal _standardFundingProposals;
    mapping(uint24 => mapping(address => QuadraticVoter)) internal _quadraticVoters;
    mapping(uint24 => mapping(address => uint256)) public screeningVotesCast;
    mapping(uint24 => mapping(address => bool)) public hasClaimedReward;
    mapping(uint24 => bool) internal _isSurplusFundsUpdated;

    constructor(address ajna_) {
        ajnaTokenAddress = ajna_;
    }

    /// @notice Seed the treasury book-value and the matching real AJNA balance.
    function fundTreasury(uint256 amount) external {
        MockAjna(ajnaTokenAddress).transferFrom(msg.sender, address(this), amount);
        treasury += amount;
    }

    /*//////////////// startNewDistributionPeriod (GBC math verbatim) ////////////////*/
    function startNewDistributionPeriod() external returns (uint24 newDistributionId_) {
        uint24 currentDistributionId = _currentDistributionId;

        // (block-number / challenge-stage gating stripped for the local reduction)
        // update Treasury with unused funds from the last distribution
        if (currentDistributionId > 0) {
            _updateTreasury(currentDistributionId);
        }

        // set new value for currentDistributionId
        newDistributionId_ = ++_currentDistributionId;

        QuarterlyDistribution storage newDistributionPeriod = _distributions[newDistributionId_];
        newDistributionPeriod.id = newDistributionId_;
        uint256 gbc = Maths.wmul(treasury, GLOBAL_BUDGET_CONSTRAINT);
        newDistributionPeriod.fundsAvailable = SafeCast.toUint128(gbc);

        // decrease the treasury by the amount that is held for allocation in the new distribution period
        treasury -= gbc;
    }

    /*//////////////// _updateTreasury (VERBATIM — the VULN) ////////////////*/
    function _updateTreasury(uint24 distributionId_) private {
        bytes32 fundedSlateHash = _distributions[distributionId_].fundedSlateHash;
        uint256 fundsAvailable = _distributions[distributionId_].fundsAvailable;

        uint256[] memory fundingProposalIds = _fundedProposalSlates[fundedSlateHash];

        uint256 totalTokensRequested;
        uint256 numFundedProposals = fundingProposalIds.length;

        for (uint256 i = 0; i < numFundedProposals;) {
            Proposal memory proposal = _standardFundingProposals[fundingProposalIds[i]];

            totalTokensRequested += proposal.tokensRequested;

            unchecked {
                ++i;
            }
        }

        // readd non distributed tokens to the treasury
        treasury += (fundsAvailable - totalTokensRequested); // @> VULN: re-adds the ~10% delegate-reward slice that was already paid out

        _isSurplusFundsUpdated[distributionId_] = true;
    }

    /*//////////////// execute a funded proposal (pays out up to 90%) ////////////////*/
    function executeStandard(uint256 proposalId_) external {
        Proposal storage proposal = _standardFundingProposals[proposalId_];
        require(!proposal.executed, "executed");
        proposal.executed = true;
        // grant tokens to the proposal recipient (leaves the treasury's real balance)
        MockAjna(ajnaTokenAddress).transfer(proposal.recipient, proposal.tokensRequested);
    }

    /*//////////////// claimDelegateReward (+ _getDelegateReward VERBATIM) ////////////////*/
    function claimDelegateReward(uint24 distributionId_) external returns (uint256 rewardClaimed_) {
        // Revert if delegatee didn't vote in screening stage
        if (screeningVotesCast[distributionId_][msg.sender] == 0) revert DelegateRewardInvalid();

        QuarterlyDistribution memory currentDistribution = _distributions[distributionId_];

        // (block-number challenge-stage check stripped for the local reduction)

        // check rewards haven't already been claimed
        if (hasClaimedReward[distributionId_][msg.sender]) revert RewardAlreadyClaimed();

        QuadraticVoter memory voter = _quadraticVoters[distributionId_][msg.sender];

        // calculate rewards earned for voting
        rewardClaimed_ = _getDelegateReward(currentDistribution, voter);

        hasClaimedReward[distributionId_][msg.sender] = true;

        emit DelegateRewardClaimed(msg.sender, distributionId_, rewardClaimed_);

        // transfer rewards to delegatee
        MockAjna(ajnaTokenAddress).transfer(msg.sender, rewardClaimed_);
    }

    function _getDelegateReward(QuarterlyDistribution memory currentDistribution_, QuadraticVoter memory voter_)
        internal
        pure
        returns (uint256 rewards_)
    {
        // calculate the total voting power available to the voter that was allocated in the funding stage
        uint256 votingPowerAllocatedByDelegatee = voter_.votingPower - voter_.remainingVotingPower;

        // if none of the voter's voting power was allocated, they receive no rewards
        if (votingPowerAllocatedByDelegatee == 0) return 0;

        // calculate reward
        // delegateeReward = 10 % of GBC distributed as per delegatee Voting power allocated
        rewards_ = Maths.wdiv(
            Maths.wmul(currentDistribution_.fundsAvailable, votingPowerAllocatedByDelegatee),
            currentDistribution_.fundingVotePowerCast
        ) / 10;
    }

    /*//////////////// reduced setup of the funding-stage RESULT (scaffolding) ////////////////*/
    function seedFundedSlate(uint24 distributionId_, uint256 proposalId_, uint256 tokensRequested_, address recipient_)
        external
    {
        bytes32 slateHash = keccak256(abi.encode(distributionId_, proposalId_));
        _standardFundingProposals[proposalId_] = Proposal({tokensRequested: tokensRequested_, recipient: recipient_, executed: false});
        _fundedProposalSlates[slateHash].push(proposalId_);
        _distributions[distributionId_].fundedSlateHash = slateHash;
    }

    function seedVoter(uint24 distributionId_, address voter_, uint128 votingPower_) external {
        _quadraticVoters[distributionId_][voter_] = QuadraticVoter({votingPower: votingPower_, remainingVotingPower: 0});
        screeningVotesCast[distributionId_][voter_] = 1;
        _distributions[distributionId_].fundingVotePowerCast += votingPower_;
    }

    /*//////////////// views ////////////////*/
    function getFundsAvailable(uint24 distributionId_) external view returns (uint256) {
        return _distributions[distributionId_].fundsAvailable;
    }
}

/// @notice A voter who claims their delegate reward (claimDelegateReward pays msg.sender).
contract Voter {
    function claim(GrantFund gf, uint24 distId) external returns (uint256) {
        return gf.claimDelegateReward(distId);
    }
}

/// @notice Orchestrates one full distribution period, then starts the next — which
///         triggers _updateTreasury and exposes the treasury over-accounting.
contract Exploit {
    // Match the finding's numbers: treasury 500M AJNA, GBC 3% = 15M, 90% grants,
    // 10% (= 1.5M) delegate rewards.
    uint256 public constant INITIAL_TREASURY = 500_000_000 ether;

    MockAjna public ajna;
    GrantFund public gf;
    Voter public v1;
    Voter public v2;
    Voter public v3;
    address public constant PROPOSAL_RECIPIENT = address(0xC0FFEE);

    // observability
    uint256 public firstGbc;
    uint256 public tokensRequested;
    uint256 public delegateRewardsPaid;
    uint256 public bookedAfterUpdate; // treasury book + amount reserved for next period
    uint256 public realBalance;

    constructor() {
        ajna = new MockAjna();                       // CREATE(exploit, 1)
        gf = new GrantFund(address(ajna));           // CREATE(exploit, 2) — vulnerable
        v1 = new Voter();                            // CREATE(exploit, 3)
        v2 = new Voter();                            // CREATE(exploit, 4)
        v3 = new Voter();                            // CREATE(exploit, 5)

        // Seed the treasury: 500M AJNA held, booked.
        ajna.mint(address(this), INITIAL_TREASURY);
        ajna.approve(address(gf), INITIAL_TREASURY);
        gf.fundTreasury(INITIAL_TREASURY);
    }

    function run() external {
        // Sanity: treasury book == real AJNA balance to start.
        require(gf.treasury() == INITIAL_TREASURY, "seed book");
        require(ajna.balanceOf(address(gf)) == INITIAL_TREASURY, "seed real");

        // === Period 1 ===
        uint24 dist1 = gf.startNewDistributionPeriod();
        firstGbc = gf.getFundsAvailable(dist1); // 15M (3% of 500M)

        // Funding-stage result: one winning proposal requesting 90% of the GBC,
        // and three voters who each fully allocated equal voting power.
        tokensRequested = (firstGbc * 9) / 10; // 13.5M
        gf.seedFundedSlate(dist1, 1, tokensRequested, PROPOSAL_RECIPIENT);
        gf.seedVoter(dist1, address(v1), 1e18);
        gf.seedVoter(dist1, address(v2), 1e18);
        gf.seedVoter(dist1, address(v3), 1e18);

        // Execute the funded proposal: 90% of the GBC leaves the treasury.
        gf.executeStandard(1);

        // Voters claim their delegate rewards: the other 10% leaves the treasury.
        delegateRewardsPaid = v1.claim(gf, dist1) + v2.claim(gf, dist1) + v3.claim(gf, dist1);

        // At this point the full GBC (90% + 10%) has been paid, and the treasury
        // book still equals the real balance — accounting is consistent.
        require(gf.treasury() == ajna.balanceOf(address(gf)), "consistent before update");

        // === Period 2 start → _updateTreasury(dist1) runs (the bug) ===
        uint24 dist2 = gf.startNewDistributionPeriod();

        // Booked value the protocol believes it controls = free treasury book +
        // the amount just reserved for period 2.
        bookedAfterUpdate = gf.treasury() + gf.getFundsAvailable(dist2);
        realBalance = ajna.balanceOf(address(gf));

        // HARM: the treasury books more AJNA than it holds — by exactly the delegate
        // rewards that were paid but wrongly re-added as "unused". Repeated every
        // period, the treasury becomes insolvent (books grants it cannot honor).
        require(bookedAfterUpdate > realBalance, "treasury must be over-accounted");
        require(bookedAfterUpdate - realBalance == delegateRewardsPaid, "over-accounting == delegate rewards paid");
        require(delegateRewardsPaid == firstGbc / 10, "delegate rewards == 10% of GBC");
        require(delegateRewardsPaid == 1_500_000 ether, "10% of 15M GBC = 1.5M AJNA");
    }
}
