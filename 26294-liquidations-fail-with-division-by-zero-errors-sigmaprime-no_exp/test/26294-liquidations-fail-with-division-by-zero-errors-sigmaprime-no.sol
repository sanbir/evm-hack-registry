// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Term Finance — a complete liquidation divides by a zero repurchase obligation
    (Sigma Prime, finding 26294).
    SYNTHETIC, cheatcode-free. liquidatorCoverExposure zeros the obligation,
    then the exposure-cap ratio divides by that zero (@> VULN). The liquidation
    reverts and 1000 collateral stays in the locker. The control returns true
    when the obligation is already 0, and the liquidator receives the 1000. */

contract MockToken {
    string public name = "COLL";
    string public symbol = "COLL";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Servicer {
    mapping(address => uint256) public obligation;

    function setObligation(address borrower, uint256 amount) external {
        obligation[borrower] = amount;
    }

    function getBorrowerRepurchaseObligation(address borrower) external view returns (uint256) {
        return obligation[borrower];
    }

    function liquidatorCoverExposure(address borrower) external {
        obligation[borrower] = 0;
    }
}

contract PriceOracle {
    function usdValueOfTokens(uint256 amount) external pure returns (uint256) {
        return amount;
    }
}

contract Locker {
    MockToken public coll;
    address public liquidator;

    constructor(address _coll, address _liquidator) {
        coll = MockToken(_coll);
        liquidator = _liquidator;
    }

    function seize(uint256 amount) external {
        coll.transfer(liquidator, amount);
    }
}

contract BatchLiquidation {
    Servicer public servicer;
    PriceOracle public oracle;
    Locker public locker;
    MockToken public coll;
    address public borrower;

    constructor(address _servicer, address _oracle, address _locker, address _coll, address _borrower) {
        servicer = Servicer(_servicer);
        oracle = PriceOracle(_oracle);
        locker = Locker(_locker);
        coll = MockToken(_coll);
        borrower = _borrower;
    }

    function _withinNetExposureCapOnLiquidation(address who) internal view returns (bool) {
        uint256 getBorrowerRepurchaseObligation = servicer.getBorrowerRepurchaseObligation(who);
        uint256 excessEquity = 1 ether;
        uint256 denom = oracle.usdValueOfTokens(getBorrowerRepurchaseObligation);
        // @> VULN: a complete liquidation leaves the repurchase obligation at 0, so this divides by zero
        uint256 ratio = excessEquity / denom;
        return ratio <= 1 ether;
    }

    function batchLiquidation() external {
        uint256 amount = coll.balanceOf(address(locker));
        servicer.liquidatorCoverExposure(borrower);
        locker.seize(amount);
        require(_withinNetExposureCapOnLiquidation(borrower), "cap");
    }
}

contract BatchLiquidationFixed {
    Servicer public servicer;
    PriceOracle public oracle;
    Locker public locker;
    MockToken public coll;
    address public borrower;

    constructor(address _servicer, address _oracle, address _locker, address _coll, address _borrower) {
        servicer = Servicer(_servicer);
        oracle = PriceOracle(_oracle);
        locker = Locker(_locker);
        coll = MockToken(_coll);
        borrower = _borrower;
    }

    function _withinNetExposureCapOnLiquidation(address who) internal view returns (bool) {
        uint256 getBorrowerRepurchaseObligation = servicer.getBorrowerRepurchaseObligation(who);
        // FIX: a borrower with nothing left to repurchase is inside the cap
        if (getBorrowerRepurchaseObligation == 0) return true;
        uint256 excessEquity = 1 ether;
        uint256 denom = oracle.usdValueOfTokens(getBorrowerRepurchaseObligation);
        uint256 ratio = excessEquity / denom;
        return ratio <= 1 ether;
    }

    function batchLiquidation() external {
        uint256 amount = coll.balanceOf(address(locker));
        servicer.liquidatorCoverExposure(borrower);
        locker.seize(amount);
        require(_withinNetExposureCapOnLiquidation(borrower), "cap");
    }
}

contract Exploit {
    MockToken public coll;
    Servicer public servicer;
    PriceOracle public oracle;
    Locker public locker;
    BatchLiquidation public liquidations;
    address public borrower;
    uint256 public constant AMOUNT = 1_000 ether;

    constructor() {
        coll = new MockToken();
        servicer = new Servicer();
        oracle = new PriceOracle();
        borrower = address(new Receiver());
        locker = new Locker(address(coll), address(this));
        liquidations = new BatchLiquidation(
            address(servicer), address(oracle), address(locker), address(coll), borrower
        );
        servicer.setObligation(borrower, 500 ether);
    }

    function run() external {
        coll.mint(address(locker), AMOUNT);
        (bool ok,) = address(liquidations).call(abi.encodeWithSelector(liquidations.batchLiquidation.selector));
        require(!ok, "liquidation reverts");
        require(coll.balanceOf(address(locker)) == AMOUNT, "collateral stuck");
        require(coll.balanceOf(address(this)) == 0, "liquidator got nothing");
        require(servicer.getBorrowerRepurchaseObligation(borrower) == 500 ether, "debt unchanged");
    }
}

contract Receiver {}
