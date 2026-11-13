// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  RFX SubaccountRouter.updateOrder calls _autoTopUpSubaccount with executionFee 0.
    nativeTokensUsed = (startingGas - gasleft()) * gasprice + executionFee, so the
    wrapped native the subaccount just deposited is missing from the refund
    (Halborn, RFX). GAS_SPENT is the fixed stand-in for that gas term (0.001 ETH)
    so the fee term is the only difference. No clock and no cheatcodes.
    Cap is 0.5 ETH. Deposit is 0.3 ETH.
    Buggy refund = 0.001 ETH. Control refund = 0.301 ETH. Gap = 0.3 ETH. */

contract Wnt {
    string public symbol = "WNT";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Harm {
    string public symbol = "UNREFUNDED";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract Subaccount {
    function approve(address token, address spender, uint256 amount) external {
        Wnt(token).approve(spender, amount);
    }
}

contract Router {
    uint256 public constant CAP = 0.5 ether;
    uint256 public constant GAS_SPENT = 0.001 ether;
    Wnt public wnt;
    address public sub;
    uint256 public executionFee;
    uint256 public refunded;

    constructor(address _wnt, address _sub) {
        wnt = Wnt(_wnt);
        sub = _sub;
    }

    function updateOrder(uint256 receivedWnt) external {
        require(wnt.transferFrom(sub, address(this), receivedWnt), "deposit");
        executionFee += receivedWnt;
        // top-up is called with executionFee 0, so the new deposit is not refunded
        _autoTopUp(0);
    }

    function _autoTopUp(uint256 executionFeeArg) internal {
        uint256 nativeTokensUsed = GAS_SPENT + executionFeeArg;
        uint256 amount = CAP;
        if (nativeTokensUsed < amount) amount = nativeTokensUsed;
        // @> VULN: executionFee argument is 0, so the refund omits the deposit
        refunded = amount; require(wnt.transfer(sub, amount), "refund");
    }
}

contract FixedRouter {
    uint256 public constant CAP = 0.5 ether;
    uint256 public constant GAS_SPENT = 0.001 ether;
    Wnt public wnt;
    address public sub;
    uint256 public executionFee;
    uint256 public refunded;

    constructor(address _wnt, address _sub) {
        wnt = Wnt(_wnt);
        sub = _sub;
    }

    function updateOrder(uint256 receivedWnt) external {
        require(wnt.transferFrom(sub, address(this), receivedWnt), "deposit");
        executionFee += receivedWnt;
        _autoTopUp(receivedWnt);
    }

    function _autoTopUp(uint256 executionFeeArg) internal {
        uint256 nativeTokensUsed = GAS_SPENT + executionFeeArg;
        uint256 amount = CAP;
        if (nativeTokensUsed < amount) amount = nativeTokensUsed;
        refunded = amount;
        require(wnt.transfer(sub, amount), "refund");
    }
}

contract Exploit {
    uint256 public constant FEE = 0.3 ether;
    uint256 public constant START = 1 ether;
    address public constant SINK = 0x000000000000000000000000000000000000D00d;

    Harm public harm;
    Wnt public wnt;
    Subaccount public buggySub;
    Subaccount public controlSub;
    Router public buggy;
    FixedRouter public fixedRouter;

    uint256 public buggyLeft;
    uint256 public controlLeft;
    uint256 public feeRecorded;
    uint256 public buggyRefund;
    uint256 public controlRefund;
    uint256 public missing;

    constructor() {
        harm = new Harm();
        wnt = new Wnt();
        buggySub = new Subaccount();
        controlSub = new Subaccount();
        buggy = new Router(address(wnt), address(buggySub));
        fixedRouter = new FixedRouter(address(wnt), address(controlSub));
        wnt.mint(address(buggySub), START);
        wnt.mint(address(controlSub), START);
        wnt.mint(address(buggy), 1 ether);
        wnt.mint(address(fixedRouter), 1 ether);
        buggySub.approve(address(wnt), address(buggy), type(uint256).max);
        controlSub.approve(address(wnt), address(fixedRouter), type(uint256).max);
    }

    function run() external {
        require(FEE == 0.3 ether, "fee");
        require(wnt.balanceOf(address(buggySub)) == START, "start");
        buggy.updateOrder(FEE);
        feeRecorded = buggy.executionFee();
        require(feeRecorded == FEE, "recorded");
        buggyRefund = buggy.refunded();
        require(buggyRefund == 0.001 ether, "gas only");
        buggyLeft = wnt.balanceOf(address(buggySub));
        require(buggyLeft == START - FEE + buggyRefund, "buggy left");
        fixedRouter.updateOrder(FEE);
        controlRefund = fixedRouter.refunded();
        require(controlRefund == 0.301 ether, "control refund");
        controlLeft = wnt.balanceOf(address(controlSub));
        require(controlLeft == START - FEE + controlRefund, "control left");
        missing = controlLeft - buggyLeft;
        require(missing == FEE, "gap");
        harm.mint(SINK, missing);
        require(harm.balanceOf(SINK) == FEE, "marked");
    }
}
