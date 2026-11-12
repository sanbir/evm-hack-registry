// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  gTrade PriceImpactUtils.getTradeSkewPriceImpactP ignores the trade's contract
    version (Pashov, H-02, 2025-05-26).
    SYNTHETIC, cheatcode-free.
    A flat book and a 100,000 USD long close have raw skew 2e8 (2%). The function
    always divides by 2, so a v9 close is charged 1e8 (1%) and the fill is 1,000 DAI
    worse. A pre-v10 close should be 0. The control reads contractsVersion. */

contract Dai {
    mapping(address => uint256) internal _balances;
    mapping(address => mapping(address => uint256)) internal _allowance;

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _allowance[from][msg.sender] -= amount;
        _balances[from] -= amount;
        _balances[to] += amount;
        return true;
    }
}

contract PriceImpact {
    int256 internal constant P_10 = 1e10;
    uint256 internal constant DEPTH = 5_000_000e18;

    Dai public dai;
    bool public useVersion;
    uint256 public fillTaken;

    constructor(Dai _dai, bool _useVersion) {
        dai = _dai;
        useVersion = _useVersion;
    }

    function _getTradePriceImpactP(int256 oiSkewUsd, int256 tradeUsd, uint256 depth) internal pure returns (int256) {
        return (oiSkewUsd + tradeUsd) * P_10 / int256(depth);
    }

    function getTradeSkewPriceImpactP(
        uint8,
        uint16,
        bool long,
        uint256 tradeOpenInterestUsd,
        bool open,
        uint8 contractsVersion
    ) external returns (int256 priceImpactP) {
        bool tradePositiveSkew = (long && open) || (!long && !open);
        int256 tradeSkewMultiplier = tradePositiveSkew ? int256(1) : int256(-1);
        int256 raw = _getTradePriceImpactP(0, int256(tradeOpenInterestUsd) * tradeSkewMultiplier, DEPTH);

        if (useVersion && contractsVersion < 10 && !open) {
            priceImpactP = 0;
        } else if (useVersion && contractsVersion < 10 && open) {
            priceImpactP = raw;
        } else {
            // @> VULN: divider is hardcoded to 2. The trade's contract version is never consulted.
            int256 priceImpactDivider = int256(2);
            priceImpactP = raw / priceImpactDivider;
        }

        uint256 magnitude = uint256(priceImpactP < 0 ? -priceImpactP : priceImpactP);
        uint256 fill = tradeOpenInterestUsd * magnitude / uint256(P_10);
        if (fill > 0) {
            dai.transferFrom(msg.sender, address(this), fill);
            fillTaken += fill;
        }
    }
}

contract Exploit {
    uint256 public constant TRADE = 100_000e18;
    uint256 public constant EXTRA = 1_000e18;
    int256 public constant CHARGED = -1e8;
    int256 public constant SHOULD = 0;

    Dai public dai; // nonce 1
    PriceImpact public book; // nonce 2
    PriceImpact public fairBook; // nonce 3

    int256 public impactVuln;
    int256 public impactControl;
    uint256 public extraFill;
    uint256 public controlFill;

    constructor() {
        dai = new Dai();
        book = new PriceImpact(dai, false);
        fairBook = new PriceImpact(dai, true);
    }

    function run() external {
        dai.mint(address(this), EXTRA);
        dai.approve(address(book), type(uint256).max);
        dai.approve(address(fairBook), type(uint256).max);

        impactVuln = book.getTradeSkewPriceImpactP(0, 0, true, TRADE, false, 9);
        extraFill = book.fillTaken();
        impactControl = fairBook.getTradeSkewPriceImpactP(0, 0, true, TRADE, false, 9);
        controlFill = fairBook.fillTaken();

        require(impactVuln == CHARGED, "half skew was not charged");
        require(impactControl == SHOULD, "control did not return 0");
        require(extraFill == EXTRA, "extra fill");
        require(controlFill == 0, "control took a fill");
    }
}
