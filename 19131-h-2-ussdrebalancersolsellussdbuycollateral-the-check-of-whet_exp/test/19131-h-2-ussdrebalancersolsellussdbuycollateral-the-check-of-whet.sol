// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  USSD — SellUSSDBuyCollateral checks DAI with `||` instead of `&&`
    (Sherlock 2023-05, finding 19131).
    SYNTHETIC, cheatcode-free. The `||` condition is the audited line (@> VULN).
    Root cause: no token is both uniPool.token0 and token1, so the OR is true
    for DAI too. pathbuy still runs and sells daibought/portions of the DAI the
    comment says was already bought. The corrected AND skips that swap. */

interface IERC20Upgradeable {
    function balanceOf(address account) external view returns (uint256);
}

interface IERC20MetadataUpgradeable {
    function decimals() external view returns (uint8);
}

interface IStableOracle {
    function getPriceUSD() external view returns (uint256);
}

interface IUniPool {
    function token0() external view returns (address);
    function token1() external view returns (address);
}

struct CollateralInfo {
    address token;
    bool mintable;
    bool redeem;
    IStableOracle oracle;
    bytes pathbuy;
    bytes pathsell;
    uint256[] ratios;
}

interface IUSSD {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function collateralFactor() external view returns (uint256);
    function collateralList() external view returns (CollateralInfo[] memory);
    function UniV3SwapInput(bytes memory path, uint256 sellAmount) external;
}

contract MockToken {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
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

    /// Pool payout. The pool holds DAI; USSD pulls it on the USSD→DAI leg.
    function pull(address from, address to, uint256 amount) external {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract UniPool {
    address public immutable token0;
    address public immutable token1;

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }
}

contract OneDollarOracle is IStableOracle {
    function getPriceUSD() external pure returns (uint256) {
        return 1e18;
    }
}

contract DaiPathSink {}

contract USSDToken is MockToken {
    address public rebalancer;
    MockToken public dai;
    MockToken public coll;
    UniPool public pool;
    address public sink;
    uint256 public wronglySold;
    CollateralInfo[] internal cols;

    constructor() MockToken("USSD", "USSD", 18) {}

    function configure(
        address _rebalancer,
        address _dai,
        address _coll,
        address _pool,
        address _sink,
        address _oracle
    ) external {
        rebalancer = _rebalancer;
        dai = MockToken(_dai);
        coll = MockToken(_coll);
        pool = UniPool(_pool);
        sink = _sink;
        delete cols;
        cols.push(_col(_dai, abi.encodePacked(_dai, uint24(100), _dai), _oracle));
        cols.push(_col(_coll, abi.encodePacked(_dai, uint24(100), _coll), _oracle));
    }

    function _col(address token, bytes memory pathbuy, address oracle) internal pure returns (CollateralInfo memory c) {
        uint256[] memory ratios = new uint256[](1);
        ratios[0] = 2_000_000;
        c.token = token;
        c.mintable = true;
        c.redeem = true;
        c.oracle = IStableOracle(oracle);
        c.pathbuy = pathbuy;
        c.ratios = ratios;
    }

    function collateralFactor() external pure returns (uint256) {
        return 0;
    }

    function collateralList() external view returns (CollateralInfo[] memory out) {
        out = new CollateralInfo[](cols.length);
        for (uint256 i = 0; i < cols.length; i++) {
            out[i] = cols[i];
        }
    }

    function UniV3SwapInput(bytes memory path, uint256 sellAmount) external {
        require(msg.sender == rebalancer, "rebalancer");
        address tokenIn = _addrAt(path, 0);
        address tokenOut = _addrAt(path, 23);
        if (tokenIn == address(this) && tokenOut == address(dai)) {
            balanceOf[address(this)] -= sellAmount;
            balanceOf[address(pool)] += sellAmount;
            dai.pull(address(pool), address(this), sellAmount);
            return;
        }
        if (tokenIn == address(dai) && tokenOut == address(coll)) {
            dai.transfer(address(pool), sellAmount);
            coll.mint(address(this), sellAmount);
            return;
        }
        if (tokenIn == address(dai) && tokenOut == address(dai)) {
            dai.transfer(sink, sellAmount);
            wronglySold += sellAmount;
            return;
        }
        revert("path");
    }

    function _addrAt(bytes memory path, uint256 start) internal pure returns (address a) {
        require(path.length >= start + 20, "short path");
        assembly {
            a := shr(96, mload(add(add(path, 32), start)))
        }
    }
}

contract USSDRebalancer {
    IUniPool public uniPool;
    address public USSD;
    uint256[] public flutterRatios;
    address public baseAsset;
    bool public immutable corrected;
    uint256 public lastDaiBought;
    uint256 public portionsFinal;

    constructor(address _ussd, address _pool, address _base, bool _corrected) {
        USSD = _ussd;
        uniPool = IUniPool(_pool);
        baseAsset = _base;
        corrected = _corrected;
        flutterRatios.push(1);
    }

    function getOwnValuation() public pure returns (uint256) {
        return 1e6;
    }

    function SellUSSDBuyCollateral() external {
        uint256 amount = IUSSD(USSD).balanceOf(USSD);
        uint256 daibought = 0;
        if (uniPool.token0() == USSD) {
            daibought = IERC20Upgradeable(baseAsset).balanceOf(USSD);
            IUSSD(USSD).UniV3SwapInput(
                bytes.concat(abi.encodePacked(uniPool.token0(), hex"0001f4", uniPool.token1())), amount
            );
            daibought = IERC20Upgradeable(baseAsset).balanceOf(USSD) - daibought;
        } else {
            daibought = IERC20Upgradeable(baseAsset).balanceOf(USSD);
            IUSSD(USSD).UniV3SwapInput(
                bytes.concat(abi.encodePacked(uniPool.token1(), hex"0001f4", uniPool.token0())), amount
            );
            daibought = IERC20Upgradeable(baseAsset).balanceOf(USSD) - daibought;
        }
        lastDaiBought = daibought;

        uint256 cf = IUSSD(USSD).collateralFactor();
        uint256 flutter = 0;
        for (flutter = 0; flutter < flutterRatios.length; flutter++) {
            if (cf < flutterRatios[flutter]) {
                break;
            }
        }

        CollateralInfo[] memory collateral = IUSSD(USSD).collateralList();
        uint256 portions = 0;
        uint256 ownval = (getOwnValuation() * 1e18 / 1e6) * IUSSD(USSD).totalSupply() / 1e6;
        for (uint256 i = 0; i < collateral.length; i++) {
            uint256 collateralval = IERC20Upgradeable(collateral[i].token).balanceOf(USSD) * 1e18
                / (10 ** IERC20MetadataUpgradeable(collateral[i].token).decimals()) * collateral[i].oracle.getPriceUSD()
                / 1e18;
            if (collateralval * 1e18 / ownval < collateral[i].ratios[flutter]) {
                portions++;
            }
        }
        portionsFinal = portions;

        for (uint256 i = 0; i < collateral.length; i++) {
            uint256 collateralval = IERC20Upgradeable(collateral[i].token).balanceOf(USSD) * 1e18
                / (10 ** IERC20MetadataUpgradeable(collateral[i].token).decimals()) * collateral[i].oracle.getPriceUSD()
                / 1e18;
            if (collateralval * 1e18 / ownval < collateral[i].ratios[flutter]) {
                if (corrected) {
                    if (collateral[i].token != uniPool.token0() && collateral[i].token != uniPool.token1()) {
                        IUSSD(USSD).UniV3SwapInput(collateral[i].pathbuy, daibought / portions);
                    }
                } else {
                    // @> VULN: `||` is true for every token, so DAI is not skipped and pathbuy sells it.
                    if (collateral[i].token != uniPool.token0() || collateral[i].token != uniPool.token1()) {
                        // don't touch DAI if it's needed to be bought (it's already bought)
                        IUSSD(USSD).UniV3SwapInput(collateral[i].pathbuy, daibought / portions);
                    }
                }
            }
        }
    }
}

contract Stack {
    MockToken public dai;
    MockToken public coll;
    USSDToken public ussd;
    UniPool public pool;
    OneDollarOracle public oracle;
    DaiPathSink public sink;
    USSDRebalancer public rebalancer;

    constructor(bool corrected) {
        dai = new MockToken("Dai", "DAI", 18);
        coll = new MockToken("Collateral", "COLL", 18);
        ussd = new USSDToken();
        pool = new UniPool(address(ussd), address(dai));
        oracle = new OneDollarOracle();
        sink = new DaiPathSink();
        rebalancer = new USSDRebalancer(address(ussd), address(pool), address(dai), corrected);
        ussd.configure(address(rebalancer), address(dai), address(coll), address(pool), address(sink), address(oracle));
        ussd.mint(address(ussd), 2000e18);
        dai.mint(address(pool), 5000e18);
    }

    function go() external {
        rebalancer.SellUSSDBuyCollateral();
    }
}

contract Exploit {
    Stack public stack;

    constructor() {
        stack = new Stack(false);
    }

    function run() external {
        stack.go();
        uint256 sold = stack.ussd().wronglySold();
        uint256 daiLeft = stack.dai().balanceOf(address(stack.ussd()));
        uint256 collBought = stack.coll().balanceOf(address(stack.ussd()));
        require(stack.rebalancer().lastDaiBought() == 2000e18, "bought");
        require(sold == 1000e18, "sold off");
        require(daiLeft == 0, "dai left");
        require(collBought == 1000e18, "coll");
        require(stack.dai().balanceOf(address(stack.sink())) == 1000e18, "sink");
    }
}
