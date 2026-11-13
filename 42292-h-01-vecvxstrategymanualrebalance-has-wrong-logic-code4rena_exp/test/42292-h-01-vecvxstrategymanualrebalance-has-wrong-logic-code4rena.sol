// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Badger veCVXStrategy.manualRebalance (Code4rena, Sep 2021, finding #42292, cmichel).
    SYNTHETIC, cheatcode-free. currentLockRatio is a 1e18 percentage.
    newLockRatio is a CVX amount. Subtracting them locks the liquid balance
    (@> VULN). Fair math, using balanceInLock, locks only 100 of the 200 liquid. */

contract Cvx {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract Locker {
    Cvx public immutable cvx;
    mapping(address => uint256) public balanceOf;

    constructor(Cvx cvx_) {
        cvx = cvx_;
    }

    function sync(address who, uint256 amt) external {
        balanceOf[who] = amt;
    }

    function lock(address who, uint256 amt) external {
        cvx.transfer(address(this), amt); // caller is the strategy, so this pulls nothing — strategy transfers first
        who;
        amt;
    }

    function pull(address from, uint256 amt) external {
        cvx.transfer(address(this), amt);
        from;
    }
}

contract VeStrategy {
    uint256 public constant MAX_BPS = 10_000;
    address public governance;
    Cvx public immutable cvx;
    Locker public immutable locker;
    uint256 public lastCvxToLock;
    uint256 public lastLocked;

    constructor(Cvx cvx_, Locker locker_) {
        cvx = cvx_;
        locker = locker_;
        governance = msg.sender;
    }

    function manualRebalance(uint256 toLock) external {
        require(msg.sender == governance, "governance");
        require(toLock <= MAX_BPS, "Max is 100%");

        uint256 balanceOfCVX = cvx.balanceOf(address(this));
        uint256 balanceInLock = locker.balanceOf(address(this));
        uint256 totalCVXBalance = balanceOfCVX + balanceInLock;

        uint256 currentLockRatio = balanceInLock * (10 ** 18) / totalCVXBalance;
        uint256 newLockRatio = totalCVXBalance * toLock / MAX_BPS;

        if (newLockRatio <= currentLockRatio) {
            return;
        }

        // @> VULN: newLockRatio is a CVX amount and currentLockRatio is a 1e18 percentage.
        uint256 cvxToLock = newLockRatio - currentLockRatio;
        lastCvxToLock = cvxToLock;

        uint256 maxCVX = cvx.balanceOf(address(this));
        if (cvxToLock > maxCVX) {
            lastLocked = maxCVX;
            cvx.transfer(address(locker), maxCVX);
            locker.sync(address(this), balanceInLock + maxCVX);
        } else {
            lastLocked = cvxToLock;
            cvx.transfer(address(locker), cvxToLock);
            locker.sync(address(this), balanceInLock + cvxToLock);
        }
    }

    function manualRebalanceFixed(uint256 toLock) external {
        require(msg.sender == governance, "governance");
        require(toLock <= MAX_BPS, "Max is 100%");
        uint256 balanceOfCVX = cvx.balanceOf(address(this));
        uint256 balanceInLock = locker.balanceOf(address(this));
        uint256 totalCVXBalance = balanceOfCVX + balanceInLock;
        uint256 newLockAmount = totalCVXBalance * toLock / MAX_BPS;
        if (newLockAmount <= balanceInLock) return;
        uint256 cvxToLock = newLockAmount - balanceInLock;
        uint256 maxCVX = cvx.balanceOf(address(this));
        if (cvxToLock > maxCVX) cvxToLock = maxCVX;
        cvx.transfer(address(locker), cvxToLock);
        locker.sync(address(this), balanceInLock + cvxToLock);
    }
}

contract Exploit {
    Cvx public cvx; // nonce 1
    Locker public locker; // nonce 2
    VeStrategy public strat; // nonce 3

    constructor() {
        cvx = new Cvx();
        locker = new Locker(cvx);
        strat = new VeStrategy(cvx, locker);
        cvx.mint(address(locker), 800 ether);
        locker.sync(address(strat), 800 ether);
        cvx.mint(address(strat), 200 ether);
    }

    function run() external {
        uint256 liquidBefore = cvx.balanceOf(address(strat));
        require(liquidBefore == 200 ether, "200 liquid");
        require(locker.balanceOf(address(strat)) == 800 ether, "800 already locked");
        strat.manualRebalance(9000);
        require(strat.lastCvxToLock() == 900 ether - 0.8 ether, "ratio gap");
        require(strat.lastLocked() == 200 ether, "liquid cap");
        require(cvx.balanceOf(address(locker)) == 1000 ether, "locker holds everything");
        require(cvx.balanceOf(address(strat)) == 0, "no liquid left");
        require(locker.balanceOf(address(strat)) == 1000 ether, "locked 1000");
    }
}
