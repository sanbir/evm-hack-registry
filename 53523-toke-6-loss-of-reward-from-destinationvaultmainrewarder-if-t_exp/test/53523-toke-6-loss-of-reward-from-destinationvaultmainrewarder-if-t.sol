// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/* Tokemak TOKE-6 (AuditVault 53523). A full exit calls
   rewarder.withdraw(..., false), so accrued rewards are not pulled.
   The destination is then popped from debtReportQueue. The next
   updateDebtReporting has nothing to claim, and 250 of base-asset
   rewards never reach totalIdle. The fixed path claims first. */

contract RewardToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MainRewarder {
    RewardToken public token;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public rewards;

    constructor(RewardToken token_) {
        token = token_;
    }

    function seed(address account, uint256 stake, uint256 reward) external {
        balanceOf[account] = stake;
        rewards[account] = reward;
    }

    function withdraw(address account, uint256 amount, bool claim) external {
        balanceOf[account] -= amount;
        if (claim) {
            uint256 r = rewards[account];
            rewards[account] = 0;
            if (r > 0) require(token.transfer(account, r), "pay");
        }
    }
}

contract Queue {
    address[] internal items;

    function push(address a) external {
        items.push(a);
    }

    function length() external view returns (uint256) {
        return items.length;
    }

    function contains(address a) external view returns (bool) {
        uint256 n = items.length;
        for (uint256 i = 0; i < n; i++) {
            if (items[i] == a) return true;
        }
        return false;
    }

    function popAddress(address a) external {
        uint256 n = items.length;
        for (uint256 i = 0; i < n; i++) {
            if (items[i] == a) {
                items[i] = items[n - 1];
                items.pop();
                return;
            }
        }
    }

    function remove(address a) external returns (bool) {
        uint256 n = items.length;
        for (uint256 i = 0; i < n; i++) {
            if (items[i] == a) {
                items[i] = items[n - 1];
                items.pop();
                return true;
            }
        }
        return false;
    }
}

contract AutoPool {
    RewardToken public token;
    MainRewarder public rewarder;
    Queue public debtReportQueue;
    Queue public withdrawalQueue;
    Queue public removalQueue;
    bool public claimBeforeRemove;
    uint256 public totalIdle;
    uint256 public destBalance;
    address public destination;
    event RemovedFromRemovalQueue(address destination);

    constructor(RewardToken token_, bool claimBeforeRemove_) {
        token = token_;
        rewarder = new MainRewarder(token_);
        debtReportQueue = new Queue();
        withdrawalQueue = new Queue();
        removalQueue = new Queue();
        claimBeforeRemove = claimBeforeRemove_;
        destination = address(0xD357);
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal {
        if (from == to) {
            return;
        }
        if (from != address(0)) {
            // @> VULN: claim is false, so accrued reward is not transferred to the auto pool
            rewarder.withdraw(from, amount, false);
        }
    }

    function _manageQueuesForDestination(address dest) internal {
        if (destBalance == 0) {
            if (claimBeforeRemove) {
                rewarder.withdraw(address(this), 0, true);
                totalIdle += token.balanceOf(address(this));
            }
            // @> VULN: popped from debt reporting while the rewarder still holds unpaid rewards
            debtReportQueue.popAddress(dest);
            withdrawalQueue.popAddress(dest);
            if (removalQueue.remove(dest)) {
                emit RemovedFromRemovalQueue(dest);
            }
        }
    }

    function load(uint256 stake, uint256 reward) external {
        destBalance = stake;
        rewarder.seed(address(this), stake, reward);
        token.mint(address(rewarder), reward);
        debtReportQueue.push(destination);
        withdrawalQueue.push(destination);
        removalQueue.push(destination);
    }

    function flashRebalanceOut() external {
        uint256 amount = destBalance;
        destBalance = 0;
        _beforeTokenTransfer(address(this), address(0), amount);
        _manageQueuesForDestination(destination);
    }

    function updateDebtReporting() external {
        if (debtReportQueue.length() == 0) return;
        rewarder.withdraw(address(this), 0, true);
        totalIdle += token.balanceOf(address(this));
    }
}

contract Exploit {
    uint256 public constant REWARD = 250 ether;
    uint256 public constant STAKE = 1_000 ether;

    RewardToken public token;
    AutoPool public pool;
    AutoPool public fixedPool;
    uint256 public lost;
    uint256 public controlIdle;

    constructor() {
        token = new RewardToken();
        pool = new AutoPool(token, false);
        fixedPool = new AutoPool(token, true);
    }

    function run() external {
        pool.load(STAKE, REWARD);
        require(token.balanceOf(address(pool.rewarder())) == REWARD, "funded");
        require(pool.debtReportQueue().length() == 1, "queued");
        pool.flashRebalanceOut();
        require(pool.debtReportQueue().length() == 0, "popped");
        require(pool.rewarder().rewards(address(pool)) == REWARD, "unclaimed");
        pool.updateDebtReporting();
        lost = token.balanceOf(address(pool.rewarder()));
        require(pool.totalIdle() == 0, "idle");
        require(lost == REWARD, "lost");
    }

    function runControl() external {
        fixedPool.load(STAKE, REWARD);
        fixedPool.flashRebalanceOut();
        controlIdle = fixedPool.totalIdle();
        require(controlIdle == REWARD, "idle");
        require(token.balanceOf(address(fixedPool)) == REWARD, "received");
        require(token.balanceOf(address(fixedPool.rewarder())) == 0, "empty");
    }
}
