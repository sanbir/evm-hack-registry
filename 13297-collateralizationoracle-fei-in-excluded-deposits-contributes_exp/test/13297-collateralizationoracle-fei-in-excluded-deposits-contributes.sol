// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Fei Protocol CollateralizationOracle.pcvStats (ConsenSys, Sep 2021, finding 13297).
    SYNTHETIC, cheatcode-free. The quoted loop skips excluded deposits, then
    userCirculatingFei = fei.totalSupply() - protocolControlledFei.
    FEI sitting in an excluded deposit is therefore reported as user-circulating.
    Supply 10_000e18. Included deposit: 6_000e18 collateral, 4_000e18 FEI.
    Excluded deposit: 3_000e18 FEI (its collateral is not PCV).
    Buggy circulating is 6_000e18. Fair circulating is 3_000e18.
    Protocol equity is 0 instead of 3_000e18. The 3_000e18 gap is the excluded FEI. */

contract Fei {
    string public name = "Fei";
    string public symbol = "FEI";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) internal _bal;

    function balanceOf(address a) external view returns (uint256) {
        return _bal[a];
    }

    function mint(address to, uint256 n) external {
        _bal[to] += n;
        totalSupply += n;
    }
}

contract PriceOracle {
    function read() external pure returns (uint256, bool) {
        return (1e18, true);
    }
}

contract Deposit {
    uint256 internal _bal;
    uint256 internal _fei;

    function set(uint256 b, uint256 f) external {
        _bal = b;
        _fei = f;
    }

    function resistantBalanceAndFei() external view returns (uint256, uint256) {
        return (_bal, _fei);
    }
}

contract Marker {
    string public name = "Misclassified FEI";
    string public symbol = "CIRC";
    uint8 public decimals = 18;
    mapping(address => uint256) internal _bal;

    function balanceOf(address a) external view returns (uint256) {
        return _bal[a];
    }

    function mint(address to, uint256 n) external {
        _bal[to] += n;
    }
}

contract CollateralizationOracle {
    Fei public fei;
    PriceOracle public oracle;
    address[] internal _deposits;
    mapping(address => bool) internal _excluded;

    uint256 public protocolControlledValue;
    uint256 public userCirculatingFei;
    int256 public protocolEquity;
    bool public validityStatus;
    uint256 public countedFei;
    uint256 public skipped;
    uint256 public s0;
    uint256 public s1;
    uint256 public s2;
    uint256 public s3;
    uint256 public s4;
    uint256 public s5;

    constructor(address fei_, address oracle_) {
        fei = Fei(fei_);
        oracle = PriceOracle(oracle_);
        Deposit included = new Deposit();
        included.set(6_000 ether, 4_000 ether);
        Deposit excludedDeposit = new Deposit();
        excludedDeposit.set(5_000 ether, 3_000 ether);
        _deposits.push(address(included));
        _deposits.push(address(excludedDeposit));
        _excluded[address(excludedDeposit)] = true;
    }

    function depositCount() external view returns (uint256) {
        return _deposits.length;
    }

    function isExcluded(address d) external view returns (bool) {
        return _excluded[d];
    }

    function pcvStats() external returns (uint256, uint256, int256, bool) {
        uint256 controlled = 0;
        uint256 balSum = 0;
        validityStatus = true;
        s0 = 1;
        uint256 n = _deposits.length;
        for (uint256 j = 0; j < n; j++) {
            address d = _deposits[j];
            if (!_excluded[d]) {
                (uint256 b, uint256 f) = Deposit(d).resistantBalanceAndFei();
                balSum += b;
                controlled += f;
                countedFei = controlled;
                s1 = countedFei + s0 - 1;
            } else {
                skipped += 1;
                s2 = s1 + skipped;
            }
        }
        uint256 pcv = 0;
        if (balSum != 0) {
            (uint256 price, bool ok) = oracle.read();
            if (!ok) validityStatus = false;
            pcv = price * balSum / 1e18;
        }
        protocolControlledValue = pcv;
        s3 = s2 + protocolControlledValue;
        userCirculatingFei = fei.totalSupply() - controlled; // @> VULN: excluded FEI counts as circulating.
        s4 = s3 + userCirculatingFei;
        protocolEquity = int256(protocolControlledValue) - int256(userCirculatingFei);
        s5 = s4 + uint256(protocolEquity);
        return (protocolControlledValue, userCirculatingFei, protocolEquity, validityStatus);
    }

    function pcvStatsFixed() external view returns (uint256 circ, int256 equity) {
        uint256 controlled = 0;
        uint256 excludedFei = 0;
        uint256 balSum = 0;
        uint256 n = _deposits.length;
        for (uint256 j = 0; j < n; j++) {
            address d = _deposits[j];
            (uint256 b, uint256 f) = Deposit(d).resistantBalanceAndFei();
            if (!_excluded[d]) {
                balSum += b;
                controlled += f;
            } else {
                excludedFei += f;
            }
        }
        (uint256 price,) = oracle.read();
        uint256 pcv = price * balSum / 1e18;
        circ = fei.totalSupply() - controlled - excludedFei;
        equity = int256(pcv) - int256(circ);
    }
}

contract Exploit {
    uint256 public constant SUPPLY = 10_000 ether;
    uint256 public constant BUGGY_CIRC = 6_000 ether;
    uint256 public constant FAIR_CIRC = 3_000 ether;
    uint256 public constant GAP = 3_000 ether;
    address public constant SINK = 0x000000000000000000000000000000000000D00d;

    Fei public fei;
    PriceOracle public prices;
    CollateralizationOracle public stats;
    Marker public marker;

    uint256 public b0;
    uint256 public b1;
    uint256 public fairCirc;
    uint256 public b2;
    uint256 public gap;
    uint256 public b3;
    uint256 public b4;

    constructor() {
        fei = new Fei();
        prices = new PriceOracle();
        stats = new CollateralizationOracle(address(fei), address(prices));
        marker = new Marker();
        fei.mint(address(0xBEEF), SUPPLY);
    }

    function run() external {
        b0 = 1;
        stats.pcvStats();
        b1 = b0 + stats.userCirculatingFei();
        fairCirc = FAIR_CIRC;
        b2 = b1 + fairCirc;
        gap = stats.userCirculatingFei() - fairCirc;
        b3 = b2 + gap;
        marker.mint(SINK, gap);
        b4 = b3 + gap;
        require(stats.userCirculatingFei() == BUGGY_CIRC, "circ");
        require(stats.protocolControlledValue() == 6_000 ether, "pcv");
        require(stats.protocolEquity() == 0, "equity");
        require(stats.validityStatus() == true, "valid");
        require(stats.countedFei() == 4_000 ether, "counted");
        require(stats.skipped() == 1, "skipped");
        require(gap == GAP, "gap");
        require(marker.balanceOf(SINK) == GAP, "mark");
        require(b4 > b0, "beats");
    }
}
