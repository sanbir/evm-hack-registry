// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Regnum Aurum — H-06 (Pashov, 2025-06-26)
    LiquidationSwap calls Curve get_dy/exchange with int128 indexes.
    Twocrypto-NG uses uint256 indexes and exchange takes a receiver.
    The selector does not match, liquidateBorrower reverts, and the
    borrower's 1000 debt stays open. The stability pool seizes nothing. */

interface ILiquidityPool {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
}

interface ITwocryptoNg {
    function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy, address receiver) external returns (uint256);
    function get_dy(uint256 i, uint256 j, uint256 dx) external view returns (uint256);
}

contract Token {
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory s) {
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract TwocryptoNg {
    Token public coin0;
    Token public coin1;

    constructor(Token a, Token b) {
        coin0 = a;
        coin1 = b;
    }

    function get_dy(uint256, uint256, uint256 dx) external pure returns (uint256) {
        return dx;
    }

    function exchange(uint256, uint256, uint256 dx, uint256 minDy, address receiver) external returns (uint256) {
        require(dx >= minDy, "min");
        require(coin0.transfer(receiver, dx), "out");
        return dx;
    }
}

contract StabilityPool {
    uint256 public seized;

    function credit(uint256 amount) external {
        seized += amount;
    }
}

contract LiquidationSwap {
    error InvalidExchange();

    ILiquidityPool public liquidityPool;
    bool public enableSlippageProtection = true;
    uint256 public slippageProtectionBps = 100;
    mapping(address => uint256) public debt;
    Token public collateral;
    StabilityPool public stability;

    constructor(ILiquidityPool pool, Token _collateral, StabilityPool _stability) {
        liquidityPool = pool;
        collateral = _collateral;
        stability = _stability;
    }

    function setDebt(address borrower, uint256 amount) external {
        debt[borrower] = amount;
    }

    function _swap(address, uint256 amount) internal {
        uint256 expectedDy = liquidityPool.get_dy(1, 0, amount); // @> VULN: [S3] int128 get_dy selector does not exist on Twocrypto-NG.
        // FIX: get_dy(uint256,uint256,uint256) and exchange(..., address receiver).
        if (expectedDy == 0) revert InvalidExchange();
        uint256 minDy = enableSlippageProtection ? (expectedDy * (10000 - slippageProtectionBps)) / 10000 : 0;
        liquidityPool.exchange(1, 0, amount, minDy);
    }

    function liquidateBorrower(address borrower, uint256 amount) external {
        _swap(msg.sender, amount); // [S2]
        debt[borrower] = 0;
        uint256 col = collateral.balanceOf(address(this));
        require(collateral.transfer(address(stability), col), "col");
        stability.credit(col);
    }
}

contract LiquidationSwapFixed {
    ITwocryptoNg public pool;
    mapping(address => uint256) public debt;
    Token public collateral;
    StabilityPool public stability;

    constructor(ITwocryptoNg _pool, Token _collateral, StabilityPool _stability) {
        pool = _pool;
        collateral = _collateral;
        stability = _stability;
    }

    function setDebt(address borrower, uint256 amount) external {
        debt[borrower] = amount;
    }

    function liquidateBorrower(address borrower, uint256 amount) external {
        uint256 expectedDy = pool.get_dy(1, 0, amount);
        uint256 minDy = (expectedDy * 9900) / 10000;
        pool.exchange(1, 0, amount, minDy, address(this));
        debt[borrower] = 0;
        uint256 col = collateral.balanceOf(address(this));
        require(collateral.transfer(address(stability), col), "col");
        stability.credit(col);
    }
}

contract Exploit {
    Token public collateral; // nonce 1
    Token public outToken; // nonce 2
    TwocryptoNg public pool; // nonce 3
    StabilityPool public stability; // nonce 4
    LiquidationSwap public swap; // nonce 5
    address public borrower = address(0xB0B);
    uint256 public constant DEBT = 1000 ether;
    bool public reverted;

    constructor() {
        collateral = new Token("COL");
        outToken = new Token("OUT");
        pool = new TwocryptoNg(outToken, collateral);
        stability = new StabilityPool();
        swap = new LiquidationSwap(ILiquidityPool(address(pool)), collateral, stability);
        collateral.mint(address(swap), 100 ether);
        outToken.mint(address(pool), 1000 ether);
        swap.setDebt(borrower, DEBT);
    }

    function run() external {
        (bool ok,) = address(swap).call(abi.encodeWithSignature("liquidateBorrower(address,uint256)", borrower, DEBT)); // [S1]
        reverted = !ok;
        require(reverted, "liquidation should revert"); // [S4]
        require(swap.debt(borrower) == DEBT, "1000 debt remains"); // [S5]
        require(stability.seized() == 0, "stability seized nothing"); // [S6]
    }
}
