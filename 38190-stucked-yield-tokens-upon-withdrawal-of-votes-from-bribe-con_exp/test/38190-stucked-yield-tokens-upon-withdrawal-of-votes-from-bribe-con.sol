// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Alchemix — Stuck yield tokens upon withdrawal of votes from Bribe contract
    (Immunefi, Saediek, finding #38190)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground. `Bribe.deposit`
    and `Bribe.withdraw` are inlined VERBATIM from Bribe.sol#L303-L329 (audited
    commit f1007439ad3a32e412468c4c42f62f676822dc1f) — `withdraw` decrements
    `balanceOf`/`totalSupply` but NEVER decrements `totalVoting`. The Exploit
    deploys a reduced Bribe + reward token, has 5 voters deposit equal shares,
    withdraws one voter's share, deposits a reward, and shows the remaining 4
    voters can only claim 80% of the reward — the withdrawn voter's 20% share
    is permanently stuck (no fork, no cheatcodes).

    Root cause: in the real contract, `Bribe.earned()` divides a voter's
    accrued reward by `_priorSupply` — a checkpoint of `totalVoting` at the
    end of the epoch (Bribe.sol#L268, #L276). Because `withdraw()` never
    decrements `totalVoting`, that checkpoint stays inflated by exactly the
    withdrawn amount even though the voter no longer has a claim. This
    reduction keeps the exact same mechanism: a single (non-checkpointed)
    `totalVoting` denominator that `withdraw()` fails to shrink, used to
    compute every voter's proportional reward share.
//////////////////////////////////////////////////////////////////////////*/

/// @notice Minimal reward token — just enough ERC20 surface for notify/claim.
contract MockRewardToken {
    string public constant name = "MOCK-TOKEN";
    string public constant symbol = "MCK";
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Reduced Bribe: deposit()/withdraw() are verbatim from the audited
///         contract. The checkpoint/earned() machinery (binary search over
///         historical balance checkpoints, per-epoch bribe accounting) is
///         reduced to a single-epoch proportional split — `totalVoting` is
///         exactly the denominator the real `earned()` uses via its
///         `_priorSupply` checkpoint, so this reduction preserves the bug's
///         mechanism (a denominator that withdraw() fails to shrink) without
///         the unrelated checkpoint bookkeeping.
contract Bribe {
    address public voter;
    MockRewardToken public rewardToken;

    /// @notice Total votes allocated to the gauge (verbatim name/semantics).
    uint256 public totalSupply;
    /// @notice Total current votes in a voting period (verbatim name/semantics).
    uint256 public totalVoting;
    mapping(uint256 => uint256) public balanceOf;

    uint256 public epochRewardAmount;
    mapping(uint256 => bool) public claimed;

    constructor(address _voter, address _rewardToken) {
        voter = _voter;
        rewardToken = MockRewardToken(_rewardToken);
    }

    // Verbatim from Bribe.sol#L303-L316.
    function deposit(uint256 amount, uint256 tokenId) external {
        require(msg.sender == voter);

        totalSupply += amount;
        balanceOf[tokenId] += amount;

        totalVoting += amount;
    }

    // Verbatim from Bribe.sol#L319-L329.
    function withdraw(uint256 amount, uint256 tokenId) external {
        require(msg.sender == voter);

        totalSupply -= amount;
        balanceOf[tokenId] -= amount;

        // @> VULN: totalVoting is NEVER decremented here — unlike deposit(),
        // which increments it. Every voter's reward share is computed against
        // this stale, too-large denominator.
        // FIX: totalVoting -= amount;
    }

    function notifyRewardAmount(uint256 amount) external {
        rewardToken.transferFrom(msg.sender, address(this), amount);
        epochRewardAmount += amount;
    }

    /// @notice Reduced getRewardForOwner/earned(): a voter's share is
    ///         `balanceOf[tokenId] * epochRewardAmount / totalVoting` — the
    ///         exact proportional-split formula the real contract uses, with
    ///         `totalVoting` standing in for the real `_priorSupply` checkpoint.
    function getRewardForOwner(uint256 tokenId) external {
        require(msg.sender == voter, "not voter");
        require(!claimed[tokenId], "already claimed");
        claimed[tokenId] = true;

        uint256 share = (balanceOf[tokenId] * epochRewardAmount) / totalVoting;
        require(share > 0, "no rewards to claim");

        rewardToken.transfer(ownerOfToken(tokenId), share);
    }

    mapping(uint256 => address) public ownerOfTokenMap;

    function setOwner(uint256 tokenId, address owner_) external {
        ownerOfTokenMap[tokenId] = owner_;
    }

    function ownerOfToken(uint256 tokenId) public view returns (address) {
        return ownerOfTokenMap[tokenId];
    }
}

/// @notice Fixed variant, for the control test: withdraw() ALSO decrements
///         totalVoting, symmetric with deposit()'s increment. Everything else
///         is identical to the vulnerable Bribe above.
contract FixedBribe {
    address public voter;
    MockRewardToken public rewardToken;

    uint256 public totalSupply;
    uint256 public totalVoting;
    mapping(uint256 => uint256) public balanceOf;

    uint256 public epochRewardAmount;
    mapping(uint256 => bool) public claimed;
    mapping(uint256 => address) public ownerOfTokenMap;

    constructor(address _voter, address _rewardToken) {
        voter = _voter;
        rewardToken = MockRewardToken(_rewardToken);
    }

    function setOwner(uint256 tokenId, address owner_) external {
        ownerOfTokenMap[tokenId] = owner_;
    }

    function deposit(uint256 amount, uint256 tokenId) external {
        require(msg.sender == voter);
        totalSupply += amount;
        balanceOf[tokenId] += amount;
        totalVoting += amount;
    }

    function withdraw(uint256 amount, uint256 tokenId) external {
        require(msg.sender == voter);
        totalSupply -= amount;
        balanceOf[tokenId] -= amount;
        totalVoting -= amount; // FIX applied: symmetric with deposit()
    }

    function notifyRewardAmount(uint256 amount) external {
        rewardToken.transferFrom(msg.sender, address(this), amount);
        epochRewardAmount += amount;
    }

    function getRewardForOwner(uint256 tokenId) external {
        require(msg.sender == voter, "not voter");
        require(!claimed[tokenId], "already claimed");
        claimed[tokenId] = true;

        uint256 share = (balanceOf[tokenId] * epochRewardAmount) / totalVoting;
        require(share > 0, "no rewards to claim");

        rewardToken.transfer(ownerOfTokenMap[tokenId], share);
    }
}

/// @notice Simulates the reported 5-voter scenario: Alice, Bob, Carol, Dan,
///         and Eve each deposit 20 votes (totalVoting = 100). Bob withdraws
///         his 20 votes before the reward is claimed. A 100 (scaled) unit
///         reward is deposited. The 4 remaining voters can only claim 80% of
///         it — Bob's 20% share is permanently stuck in the contract, exactly
///         as described in the finding.
contract Exploit {
    Bribe public bribe;
    MockRewardToken public rewardToken;

    uint256 public constant ALICE = 1;
    uint256 public constant BOB = 2;
    uint256 public constant CAROL = 3;
    uint256 public constant DAN = 4;
    uint256 public constant EVE = 5;

    uint256 public constant VOTE_AMOUNT = 20e18;
    uint256 public constant REWARD_AMOUNT = 100e18;

    address public constant ALICE_OWNER = address(0x1001);
    address public constant BOB_OWNER = address(0x1002);
    address public constant CAROL_OWNER = address(0x1003);
    address public constant DAN_OWNER = address(0x1004);
    address public constant EVE_OWNER = address(0x1005);

    constructor() {
        rewardToken = new MockRewardToken();
        bribe = new Bribe(address(this), address(rewardToken));

        bribe.setOwner(ALICE, ALICE_OWNER);
        bribe.setOwner(BOB, BOB_OWNER);
        bribe.setOwner(CAROL, CAROL_OWNER);
        bribe.setOwner(DAN, DAN_OWNER);
        bribe.setOwner(EVE, EVE_OWNER);

        rewardToken.mint(address(this), REWARD_AMOUNT);
    }

    function run() external {
        // 5 voters each deposit 20 votes -> totalVoting = 100.
        bribe.deposit(VOTE_AMOUNT, ALICE);
        bribe.deposit(VOTE_AMOUNT, BOB);
        bribe.deposit(VOTE_AMOUNT, CAROL);
        bribe.deposit(VOTE_AMOUNT, DAN);
        bribe.deposit(VOTE_AMOUNT, EVE);
        require(bribe.totalVoting() == 5 * VOTE_AMOUNT, "setup: totalVoting should be 100 units");

        // Bob withdraws his votes before rewards are claimed.
        bribe.withdraw(VOTE_AMOUNT, BOB);

        // HARM SETUP: totalVoting is UNCHANGED after Bob's withdrawal — it
        // should have dropped to 80 units (4 remaining voters * 20 each).
        require(bribe.totalVoting() == 5 * VOTE_AMOUNT, "VULN observed: totalVoting did not shrink after withdraw");

        // A reward is deposited for the epoch (notifyRewardAmount pulls
        // REWARD_AMOUNT from address(this) via transferFrom).
        bribe.notifyRewardAmount(REWARD_AMOUNT);

        // The 4 remaining voters claim their share.
        bribe.getRewardForOwner(ALICE);
        bribe.getRewardForOwner(CAROL);
        bribe.getRewardForOwner(DAN);
        bribe.getRewardForOwner(EVE);

        uint256 totalDistributed = rewardToken.balanceOf(ALICE_OWNER) +
            rewardToken.balanceOf(CAROL_OWNER) +
            rewardToken.balanceOf(DAN_OWNER) +
            rewardToken.balanceOf(EVE_OWNER);

        uint256 stuckInBribe = rewardToken.balanceOf(address(bribe));

        // HARM: only 80% of the deposited reward was distributable; the
        // remaining 20% (Bob's rightful share) is permanently stuck in the
        // Bribe contract with no path to recovery (Bob withdrew, so his
        // balanceOf is 0 and his share now computes to 0 forever).
        require(totalDistributed == (REWARD_AMOUNT * 4) / 5, "harm not demonstrated: should distribute exactly 80%");
        require(stuckInBribe == REWARD_AMOUNT / 5, "harm not demonstrated: 20% must be stuck in the contract");
        require(stuckInBribe > 0, "harm not demonstrated: stuck amount must be nonzero");
    }
}
