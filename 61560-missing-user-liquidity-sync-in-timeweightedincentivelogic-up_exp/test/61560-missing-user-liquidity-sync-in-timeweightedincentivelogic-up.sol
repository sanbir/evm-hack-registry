// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Paladin Valkyrie — TimeWeightedIncentiveLogic never syncs user liquidity
    (Cyfrin / Draiakoo, finding #61560, 12 March 2025).

    SYNTHETIC, cheatcode-free. `nowTs` stands in for `block.timestamp`.
    depositRewards copies total liquidity from the manager and does not copy
    the user. _updateAllUserState does not copy it either, so a sole staker
    whose liquidity was registered before this logic was attached claims 0
    of N = 1000 RWD. A later syncUser cannot recover it. Control copies the
    user balance before the checkpoint and pays N. */

contract Token {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        require(allowance[from][msg.sender] >= amount, "allow");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Manager {
    uint256 public totalLiquidity;
    mapping(address => uint256) public userLiquidity;

    function addLiquidity(address account, uint256 amount) external {
        totalLiquidity += amount;
        userLiquidity[account] += amount;
    }
}

contract Logic {
    uint256 public constant UNIT = 1e18;

    Token public reward;
    Manager public manager;
    uint256 public nowTs;
    uint256 public totalLiquidity;
    uint256 public ratePerSec;
    uint256 public endTimestamp;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    bool public poolSynced;
    mapping(address => uint256) public userLiquidity;
    mapping(address => uint256) public userLast;
    mapping(address => uint256) public pending;

    constructor(Token _reward, Manager _manager) {
        reward = _reward;
        manager = _manager;
        nowTs = 1_700_000_000;
    }

    function advance(uint256 dt) external {
        nowTs += dt;
    }

    function depositRewards(uint256 amount, uint256 duration) external {
        require(duration > 0, "duration");
        if (!poolSynced) {
            totalLiquidity = manager.totalLiquidity();
            poolSynced = true;
        }
        ratePerSec = amount / duration;
        endTimestamp = nowTs + duration;
        lastUpdateTime = nowTs;
        reward.transferFrom(msg.sender, address(this), amount);
    }

    function syncUser(address account) external {
        userLiquidity[account] = manager.userLiquidity(account);
    }

    function claim() external returns (uint256 paid) {
        _updateAllUserState(msg.sender);
        paid = pending[msg.sender];
        pending[msg.sender] = 0;
        if (paid != 0) reward.transfer(msg.sender, paid);
    }

    function _updateAllUserState(address account) internal {
        address[] memory _tokens = new address[](1);
        _tokens[0] = address(reward);
        uint256 _length = _tokens.length;
        for (uint256 i; i < _length; i++) {
            _updateRewardState(account);
        }
    }

    function _updateRewardState(address account) internal {
        uint256 newRpt = _newRewardPerToken();
        // @> VULN: user liquidity was never synced, so this product pays 0
        // FIX: copy manager.userLiquidity(account) before the checkpoint
        uint256 earned = (userLiquidity[account] * (newRpt - userLast[account])) / UNIT;
        pending[account] = earned;
        userLast[account] = newRpt;
        rewardPerTokenStored = newRpt;
        uint256 applicable = nowTs < endTimestamp ? nowTs : endTimestamp;
        lastUpdateTime = applicable;
    }

    function _newRewardPerToken() internal view returns (uint256) {
        if (totalLiquidity == 0) return rewardPerTokenStored;
        uint256 applicable = nowTs < endTimestamp ? nowTs : endTimestamp;
        return rewardPerTokenStored + (((applicable - lastUpdateTime) * ratePerSec * UNIT) / totalLiquidity);
    }
}

contract Exploit {
    uint256 public constant N = 1000 ether;
    uint256 public constant LIQ = 100 ether;
    uint256 public constant DUR = 1000;

    Token public reward;
    Manager public manager;
    Logic public logic;
    uint256 public paid;
    uint256 public paidAfterSync;
    uint256 public stuck;
    uint256 public userOnLogic;

    constructor() {
        reward = new Token("Reward", "RWD", 18); // nonce 1
        manager = new Manager(); // nonce 2
        logic = new Logic(reward, manager); // nonce 3
    }

    function run() external {
        manager.addLiquidity(address(this), LIQ);
        reward.mint(address(this), N);
        reward.approve(address(logic), N);
        logic.depositRewards(N, DUR);
        logic.advance(DUR);
        paid = logic.claim();
        userOnLogic = logic.userLiquidity(address(this));
        logic.syncUser(address(this));
        paidAfterSync = logic.claim();
        stuck = reward.balanceOf(address(logic));
        require(userOnLogic == 0, "user liquidity was synced");
        require(paid == 0, "first claim was not 0");
        require(paidAfterSync == 0, "later sync recovered rewards");
        require(stuck == N, "fair amount was not stuck");
    }
}

/// @dev Control: _updateAllUserState copies manager user liquidity before the checkpoint.
contract LogicFixed {
    uint256 public constant UNIT = 1e18;

    Token public reward;
    Manager public manager;
    uint256 public nowTs;
    uint256 public totalLiquidity;
    uint256 public ratePerSec;
    uint256 public endTimestamp;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    bool public poolSynced;
    mapping(address => uint256) public userLiquidity;
    mapping(address => uint256) public userLast;
    mapping(address => bool) public userSynced;

    constructor(Token _reward, Manager _manager) {
        reward = _reward;
        manager = _manager;
        nowTs = 1_700_000_000;
    }

    function advance(uint256 dt) external {
        nowTs += dt;
    }

    function depositRewards(uint256 amount, uint256 duration) external {
        require(duration > 0, "duration");
        if (!poolSynced) {
            totalLiquidity = manager.totalLiquidity();
            poolSynced = true;
        }
        ratePerSec = amount / duration;
        endTimestamp = nowTs + duration;
        lastUpdateTime = nowTs;
        reward.transferFrom(msg.sender, address(this), amount);
    }

    function claim() external returns (uint256 paid) {
        if (!userSynced[msg.sender]) {
            userLiquidity[msg.sender] = manager.userLiquidity(msg.sender);
            userSynced[msg.sender] = true;
        }
        uint256 newRpt = _newRewardPerToken();
        paid = (userLiquidity[msg.sender] * (newRpt - userLast[msg.sender])) / UNIT;
        userLast[msg.sender] = newRpt;
        rewardPerTokenStored = newRpt;
        if (paid != 0) reward.transfer(msg.sender, paid);
    }

    function _newRewardPerToken() internal view returns (uint256) {
        if (totalLiquidity == 0) return rewardPerTokenStored;
        uint256 applicable = nowTs < endTimestamp ? nowTs : endTimestamp;
        return rewardPerTokenStored + (((applicable - lastUpdateTime) * ratePerSec * UNIT) / totalLiquidity);
    }
}
