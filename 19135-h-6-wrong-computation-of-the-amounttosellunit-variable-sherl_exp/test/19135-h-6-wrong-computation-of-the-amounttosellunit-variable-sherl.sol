// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  USSD — BuyUSSDSellCollateral computes amountToSellUnits with an extra 1e18
    (Sherlock 2023-05, finding 19135).
    SYNTHETIC, cheatcode-free. The assignment is the audited line (@> VULN).
    Root cause: the partial-sell ratio is divided by 1e18 before it is scaled
    by the collateral balance. In the branch collateralval > amountToBuyLeftUSD
    that ratio truncates to 0, so the rebalancer sells 0 instead of
    balance * amountToBuyLeftUSD / collateralval. */

interface IERC20Upgradeable {
    function balanceOf(address account) external view returns (uint256);
}

interface IERC20MetadataUpgradeable {
    function decimals() external view returns (uint8);
}

interface IStableOracle {
    function getPriceUSD() external view returns (uint256);
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
    function collateralList() external view returns (CollateralInfo[] memory);
    function UniV3SwapInput(bytes memory path, uint256 sellAmount) external;
}

contract MockToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function pull(address from, address to, uint256 amount) external {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract OneDollarOracle is IStableOracle {
    function getPriceUSD() external pure returns (uint256) {
        return 1e18;
    }
}

contract USSDToken is MockToken {
    address public rebalancer;
    MockToken public dai;
    MockToken public coll;
    address public pool;
    uint256 public daiRaised;
    uint256 public lastSellAmount;
    CollateralInfo[] internal cols;

    constructor() MockToken("USSD", "USSD") {}

    function configure(address _rebalancer, address _dai, address _coll, address _pool, address _oracle) external {
        rebalancer = _rebalancer;
        dai = MockToken(_dai);
        coll = MockToken(_coll);
        pool = _pool;
        delete cols;
        cols.push(_col(_coll, abi.encodePacked(_coll, uint24(100), _dai), _oracle));
    }

    function _col(address token, bytes memory pathsell, address oracle) internal pure returns (CollateralInfo memory c) {
        uint256[] memory ratios = new uint256[](1);
        ratios[0] = 1;
        c.token = token;
        c.mintable = true;
        c.redeem = true;
        c.oracle = IStableOracle(oracle);
        c.pathsell = pathsell;
        c.ratios = ratios;
    }

    function collateralList() external view returns (CollateralInfo[] memory out) {
        out = new CollateralInfo[](cols.length);
        for (uint256 i = 0; i < cols.length; i++) {
            out[i] = cols[i];
        }
    }

    /// 1 COLL sells for 1 DAI. A zero input records the call and moves nothing.
    function UniV3SwapInput(bytes memory, uint256 sellAmount) external {
        require(msg.sender == rebalancer, "rebalancer");
        lastSellAmount = sellAmount;
        if (sellAmount == 0) {
            return;
        }
        coll.pull(address(this), pool, sellAmount);
        dai.pull(pool, address(this), sellAmount);
        daiRaised += sellAmount;
    }
}

contract USSDRebalancer {
    address public USSD;
    address public baseAsset;
    bool public corrected;
    uint256 public soldUnits;
    uint256 public daiRaised;

    constructor(address _ussd, address _base, bool _corrected) {
        USSD = _ussd;
        baseAsset = _base;
        corrected = _corrected;
    }

    /// Correct partial-sell size: the USD fraction of the collateral balance.
    function quoteFair(uint256 balance, uint256 amountToBuyLeftUSD, uint256 collateralval) public pure returns (uint256) {
        return balance * amountToBuyLeftUSD / collateralval;
    }

    function BuyUSSDSellCollateral(uint256 amountToBuy) external {
        CollateralInfo[] memory collateral = IUSSD(USSD).collateralList();
        uint256 amountToBuyLeftUSD = amountToBuy * 1e12;
        uint256 DAItosell = 0;
        for (uint256 i = 0; i < collateral.length; i++) {
            uint256 collateralval = IERC20Upgradeable(collateral[i].token).balanceOf(USSD) * 1e18
                / (10 ** IERC20MetadataUpgradeable(collateral[i].token).decimals()) * collateral[i].oracle.getPriceUSD()
                / 1e18;
            if (collateralval > amountToBuyLeftUSD) {
                if (collateral[i].pathsell.length > 0) {
                    uint256 amountBefore = IERC20Upgradeable(baseAsset).balanceOf(USSD);
                    uint256 amountToSellUnits;
                    if (corrected) {
                        amountToSellUnits = IERC20Upgradeable(collateral[i].token).balanceOf(USSD) * amountToBuyLeftUSD
                            / collateralval;
                    } else {
                        // @> VULN: the ratio is divided by 1e18 before scaling by balance, so it truncates to 0.
                        amountToSellUnits = IERC20Upgradeable(collateral[i].token).balanceOf(USSD)
                            * ((amountToBuyLeftUSD * 1e18 / collateralval) / 1e18) / 1e18;
                    }
                    soldUnits = amountToSellUnits;
                    IUSSD(USSD).UniV3SwapInput(collateral[i].pathsell, amountToSellUnits);
                    amountToBuyLeftUSD -= (IERC20Upgradeable(baseAsset).balanceOf(USSD) - amountBefore);
                    DAItosell += (IERC20Upgradeable(baseAsset).balanceOf(USSD) - amountBefore);
                } else {
                    DAItosell = IERC20Upgradeable(collateral[i].token).balanceOf(USSD) * amountToBuyLeftUSD / collateralval;
                }
                break;
            }
        }
        daiRaised = DAItosell;
    }
}

contract Stack {
    MockToken public dai;
    MockToken public coll;
    USSDToken public ussd;
    OneDollarOracle public oracle;
    address public pool;
    USSDRebalancer public rebalancer;

    constructor(bool corrected) {
        dai = new MockToken("Dai", "DAI");
        coll = new MockToken("Collateral", "COLL");
        ussd = new USSDToken();
        oracle = new OneDollarOracle();
        pool = address(uint160(uint256(keccak256("pool"))));
        rebalancer = new USSDRebalancer(address(ussd), address(dai), corrected);
        ussd.configure(address(rebalancer), address(dai), address(coll), pool, address(oracle));
        coll.mint(address(ussd), 1000e18);
        dai.mint(pool, 1000e18);
    }

    function go(uint256 amountToBuy) external {
        rebalancer.BuyUSSDSellCollateral(amountToBuy);
    }
}

contract Exploit {
    Stack public stack;
    uint256 public fairUnits;

    constructor() {
        stack = new Stack(false);
    }

    function run() external {
        stack.go(250e6);
        uint256 sold = stack.rebalancer().soldUnits();
        fairUnits = stack.rebalancer().quoteFair(1000e18, 250e18, 1000e18);
        uint256 raised = stack.rebalancer().daiRaised();
        require(sold == 0, "buggy sold");
        require(fairUnits == 250e18, "fair");
        require(raised == 0, "raised");
        require(stack.coll().balanceOf(address(stack.ussd())) == 1000e18, "unsold");
    }
}
