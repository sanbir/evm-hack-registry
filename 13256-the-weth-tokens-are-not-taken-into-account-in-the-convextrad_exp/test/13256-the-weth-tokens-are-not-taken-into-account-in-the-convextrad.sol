// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Brahma ConvexTradeExecutor.totalFunds (ConsenSys, May 2022, finding 13256).
    SYNTHETIC, cheatcode-free. Quoted sum:
      stakedLpBalanceInETH + lpTokenBalanceInETH + address(this).balance
    WETH.balanceOf(this) is not in that sum. The executor is funded with
    20e18 staked LP (already in ETH), 5e18 idle LP (in ETH), 3 ETH, and 10 WETH.
    totalFunds returns 28e18. The position is worth 38e18. The missing 10e18 is the WETH. */

contract Weth {
    string public name = "Wrapped Ether";
    string public symbol = "WETH";
    uint8 public decimals = 18;
    mapping(address => uint256) internal _bal;

    function balanceOf(address a) external view returns (uint256) {
        return _bal[a];
    }

    function mint(address to, uint256 n) external {
        _bal[to] += n;
    }
}

contract Marker {
    string public name = "Omitted WETH";
    string public symbol = "OMIT";
    uint8 public decimals = 18;
    mapping(address => uint256) internal _bal;

    function balanceOf(address a) external view returns (uint256) {
        return _bal[a];
    }

    function mint(address to, uint256 n) external {
        _bal[to] += n;
    }
}

contract ConvexTradeExecutor {
    Weth public weth;
    uint256 public stakedLpInEth;
    uint256 public lpInEth;
    uint256 public stakedOut;
    uint256 public lpOut;
    uint256 public ethOut;
    uint256 public reported;
    uint256 public s1;
    uint256 public s2;
    uint256 public s3;

    constructor(address weth_, uint256 staked_, uint256 lp_) {
        weth = Weth(weth_);
        stakedLpInEth = staked_;
        lpInEth = lp_;
    }

    receive() external payable {}

    function totalFunds() external returns (uint256, uint256) {
        _getTotalBalancesInETH();
        uint256 amount = stakedOut + lpOut + ethOut; // @> VULN: ETH is included. WETH is not.
        reported = amount;
        s3 = s2 + reported;
        return (amount, block.number);
    }

    function _getTotalBalancesInETH() internal {
        stakedOut = stakedLpInEth;
        s1 = stakedOut;
        lpOut = lpInEth;
        s2 = s1 + lpOut;
        ethOut = address(this).balance;
    }
}

contract ConvexTradeExecutorFixed {
    Weth public weth;
    uint256 public stakedLpInEth;
    uint256 public lpInEth;
    uint256 public reported;

    constructor(address weth_, uint256 staked_, uint256 lp_) {
        weth = Weth(weth_);
        stakedLpInEth = staked_;
        lpInEth = lp_;
    }

    receive() external payable {}

    function totalFunds() external returns (uint256, uint256) {
        uint256 ethBal = address(this).balance;
        uint256 wethBal = weth.balanceOf(address(this));
        uint256 amount = stakedLpInEth + lpInEth + ethBal + wethBal;
        reported = amount;
        return (amount, block.number);
    }
}

contract Exploit {
    uint256 public constant STAKED = 20 ether;
    uint256 public constant LP = 5 ether;
    uint256 public constant WETH_AMT = 10 ether;
    uint256 public constant BUGGY = 28 ether;
    uint256 public constant FAIR = 38 ether;
    uint256 public constant GAP = 10 ether;
    address public constant SINK = 0x000000000000000000000000000000000000D00d;

    Weth public weth;
    ConvexTradeExecutor public exec;
    Marker public marker;

    uint256 public b0;
    uint256 public b1;
    uint256 public b2;
    uint256 public wethSeen;
    uint256 public b3;
    uint256 public fairTotal;
    uint256 public b4;
    uint256 public omitted;
    uint256 public b5;
    uint256 public b6;

    constructor() {
        weth = new Weth();
        exec = new ConvexTradeExecutor(address(weth), STAKED, LP);
        marker = new Marker();
        weth.mint(address(exec), WETH_AMT);
    }

    function run() external payable {
        b0 = msg.value;
        (bool ok,) = address(exec).call{value: msg.value}("");
        require(ok, "eth");
        b1 = b0 + address(exec).balance;
        (uint256 got, uint256 atBlock) = exec.totalFunds();
        b2 = b1 + got;
        wethSeen = weth.balanceOf(address(exec));
        b3 = b2 + wethSeen;
        fairTotal = got + wethSeen;
        b4 = b3 + fairTotal;
        omitted = fairTotal - got;
        b5 = b4 + omitted;
        marker.mint(SINK, omitted);
        b6 = b5 + omitted;
        require(msg.value == 3 ether, "value");
        require(got == BUGGY, "got");
        require(fairTotal == FAIR, "fair");
        require(omitted == GAP, "gap");
        require(exec.ethOut() == 3 ether, "ethbal");
        require(exec.stakedOut() == STAKED, "staked");
        require(exec.lpOut() == LP, "lp");
        require(wethSeen == WETH_AMT, "weth");
        require(marker.balanceOf(SINK) == GAP, "mark");
        require(atBlock == block.number, "block");
    }
}
